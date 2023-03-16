; Run-Time System

; Basic types

%Env = type ptr

; Reference counts
%Rc = type i64

; Code to share (bump rc) an environment
%Sharer = type ptr

; Code to drop an environment
%Eraser = type ptr

; Every heap object starts with a header
%Header = type {%Rc, %Eraser}

; A heap object is a pointer to a header followed by payload.
;
;   +--[ Header ]--+-------------+
;   | Rc  | Eraser | Payload ... |
;   +--------------+-------------+
%Obj = type ptr


; A Frame has the following layout
;
;   +-------[ FrameHeader ]-----+--------------+
;   | RetAdr  | Sharer | Eraser | Payload ...  |
;   +---------------------------+--------------+

; A stack pointer points to the top-most frame followed by all other frames.
;
; For example
;
;     +--------------------+   <- Limit
;     :                    :
;     :                    :   <- Sp
;     +--------------------+
;     | FrameHeader        |
;     |    z               |
;     |    y               |
;     |    x               |
;     +--------------------+
;     | ... next frame ... |
;     +--------------------+
;     :        ...         :
;     +--------------------+ <- Base
%Sp = type ptr
%Base = type %Sp
%Limit = type %Sp
%RetAdr = type ptr
%FrameHeader = type { %RetAdr, %Sharer, %Eraser }

; Pointers for a heap allocated stack
%Mem = type { %Sp, %Base, %Limit }

; The garbage collector differentiates three groups of types:
; - Values (Integer, Double)
; - Objects (Positive, Negative)
; - Strings
; For each group we have an arena where mutable state is allocated.
;
%Region = type [ 3 x %Mem ]

; The "meta" stack (a stack of stacks)
%Stk = type ptr

; This is used for two purposes:
;   - a refied first-class stack (then the last field is null)
;   - as part of an intrusive linked-list of stacks (meta stack)
%StkVal = type { %Rc, %Mem, %Region, %Stk }

; Positive data types consist of a (type-local) tag and a heap object
%Pos = type {i64, %Obj}
%Boolean = type %Pos
%Unit = type %Pos

; Negative types (codata) consist of a vtable and a heap object
%Neg = type {ptr, %Obj}

; Offset within the arena
%Ref = type i64

; Global locations

@base = private global %Base null
@limit = private global %Limit null
@region = private global %Region zeroinitializer
@rest = private global %Stk undef


define %StkVal @getStk(%Sp %sp) alwaysinline {
    %base = load %Base, ptr @base
    %limit = load %Limit, ptr @limit
    %region = load %Region, ptr @region
    %rest = load %Stk, ptr @rest

    %stk.0 = insertvalue %StkVal undef, %Rc 0, 0
    %stk.1 = insertvalue %StkVal %stk.0, %Sp %sp, 1, 0
    %stk.2 = insertvalue %StkVal %stk.1, %Base %base, 1, 1
    %stk.3 = insertvalue %StkVal %stk.2, %Limit %limit, 1, 2
    %stk.4 = insertvalue %StkVal %stk.3, %Region %region, 2
    %stk.5 = insertvalue %StkVal %stk.4, %Stk %rest, 3

    ret %StkVal %stk.5
}

define void @setStk(%StkVal %stk) alwaysinline {
    %base = extractvalue %StkVal %stk, 1, 1
    %limit = extractvalue %StkVal %stk, 1, 2
    %region = extractvalue %StkVal %stk, 2
    %rest = extractvalue %StkVal %stk, 3

    store %Base %base, ptr @base
    store %Limit %limit, ptr @limit
    store %Region %region, ptr @region
    store %Stk %rest, ptr @rest
    ret void
}

; Foreign imports

declare ptr @malloc(i64)
declare void @free(ptr)
declare ptr @realloc(ptr, i64)
declare void @memcpy(ptr, ptr, i64)
declare i64 @llvm.ctlz.i64 (i64 , i1)
declare i64 @llvm.fshr.i64(i64, i64, i64)
declare void @print(i64)
declare void @exit(i64)

; Garbage collection

define %Obj @newObject(%Eraser %eraser, i64 %envsize) alwaysinline {
    ; This magical 16 is the size of the object header
    %size = add i64 %envsize, 16
    %obj = call ptr @malloc(i64 %size)
    %objrc = getelementptr %Header, ptr %obj, i64 0, i32 0
    %objeraser = getelementptr %Header, ptr %obj, i64 0, i32 1
    store %Rc 0, ptr %objrc
    store %Eraser %eraser, ptr %objeraser
    ret %Obj %obj
}

define %Env @objectEnvironment(%Obj %obj) alwaysinline {
    ; Environment is stored right after header
    %env = getelementptr %Header, ptr %obj, i64 1
    ret %Env %env
}

define void @shareObject(%Obj %obj) alwaysinline {
    %isnull = icmp eq %Obj %obj, null
    br i1 %isnull, label %done, label %next

    next:
    %objrc = getelementptr %Header, ptr %obj, i64 0, i32 0
    %rc = load %Rc, ptr %objrc
    %rc.1 = add %Rc %rc, 1
    store %Rc %rc.1, ptr %objrc
    br label %done

    done:
    ret void
}

define void @sharePositive(%Pos %val) alwaysinline {
    %obj = extractvalue %Pos %val, 1
    tail call void @shareObject(%Obj %obj)
    ret void
}

define void @shareNegative(%Neg %val) alwaysinline {
    %obj = extractvalue %Neg %val, 1
    tail call void @shareObject(%Obj %obj)
    ret void
}

define void @eraseObject(%Obj %obj) alwaysinline {
    %isnull = icmp eq %Obj %obj, null
    br i1 %isnull, label %done, label %next

    next:
    %objrc = getelementptr %Header, ptr %obj, i64 0, i32 0
    %rc = load %Rc, ptr %objrc
    switch %Rc %rc, label %decr [%Rc 0, label %free]

    decr:
    %rc.1 = sub %Rc %rc, 1
    store %Rc %rc.1, ptr %objrc
    ret void

    free:
    %objeraser = getelementptr %Header, ptr %obj, i64 0, i32 1
    %eraser = load %Eraser, ptr %objeraser
    %env = call %Env @objectEnvironment(%Obj %obj)
    call fastcc void %eraser(%Env %env)
    call void @free(%Obj %obj)
    br label %done

    done:
    ret void
}

define void @erasePositive(%Pos %val) alwaysinline {
    %obj = extractvalue %Pos %val, 1
    tail call void @eraseObject(%Obj %obj)
    ret void
}

define void @eraseNegative(%Neg %val) alwaysinline {
    %obj = extractvalue %Neg %val, 1
    tail call void @eraseObject(%Obj %obj)
    ret void
}


; Arena management
define ptr @getRegionPointer(i64 %evidence) alwaysinline {
entry:
    switch i64 %evidence, label %loop [i64 0, label %here]

here:
    ret ptr @region

loop:
    %stkp = phi ptr [@rest, %entry], [%nextp, %loop]
    %stk = load %Stk, ptr %stkp
    %dec = sub i64 %evidence, 1
    %regionp = getelementptr %StkVal, %Stk %stk, i64 0, i32 2
    %nextp = getelementptr %StkVal, %Stk %stk, i64 0, i32 3
    %cmp = icmp eq i64 %dec, 0
    br i1 %cmp, label %done, label %loop

done:
    ret ptr %regionp

}



define { ptr, %Ref } @alloc(i64 %idx, i64 %evidence) alwaysinline {
    %regionp = call ptr @getRegionPointer(i64 %evidence)
    %spp = getelementptr %Region, ptr %regionp, i64 0, i64 %idx, i32 0
    %basep = getelementptr %Region, ptr %regionp, i64 0, i64 %idx, i32 1
    %limitp = getelementptr %Region, ptr %regionp, i64 0, i64 %idx, i32 2

    %sp = load %Sp, ptr %spp
    %base = load %Base, ptr %basep
    %limit = load %Limit, ptr %limitp

    %obj = icmp ne i64 %idx, 0
    %size = select i1 %obj, i64 16, i64 8

    %nextsp = getelementptr i8, %Sp %sp, i64 %size

    %cmp = icmp ule %Sp %nextsp, %limit
    br i1 %cmp, label %continue, label %realloc

continue:
    store %Sp %nextsp, ptr %spp
    %intb = ptrtoint %Base %base to i64
    %intsp = ptrtoint %Sp %sp to i64
    %offset = sub i64 %intsp, %intb

    %ret.0 = insertvalue { ptr, %Ref } undef, %Sp %sp, 0
    %ret.1 = insertvalue { ptr, %Ref } %ret.0, %Ref %offset, 1
    ret { ptr, %Ref } %ret.1

realloc:
    %intbase = ptrtoint %Base %base to i64
    %intlimit = ptrtoint %Limit %limit to i64
    %arenasize = sub i64 %intlimit, %intbase
    %newarenasize = add i64 %arenasize, 1024

    %newbase = call ptr @realloc(ptr %base, i64 %newarenasize)
    %newlimit = getelementptr i8, %Base %newbase, i64 %newarenasize
    %newsp = getelementptr i8, %Base %newbase, i64 %arenasize
    %newnextsp = getelementptr i8, %Sp %newsp, i64 %size

    store %Base %newbase, ptr %basep
    store %Limit %newlimit, ptr %limitp
    store %Sp %newnextsp, ptr %spp

    %ret..0 = insertvalue { ptr, %Ref } undef, %Sp %newsp, 0
    %ret..1 = insertvalue { ptr, %Ref } %ret..0, %Ref %arenasize, 1
    ret { ptr, %Ref } %ret..1

}

define ptr @getPtr(%Ref %ref, i64 %idx, i64 %evidence) alwaysinline {
    %regionp = call ptr @getRegionPointer(i64 %evidence)
    %basep = getelementptr %Region, ptr %regionp, i64 0, i64 %idx, i32 1
    %base = load %Base, ptr %basep
    %ptr = getelementptr i8, ptr %base, %Ref %ref
    ret ptr %ptr
}

; Meta-stack management

define %Mem @newMem() alwaysinline {
    %sp = call %Sp @malloc(i64 1024)
    %limit = getelementptr i8, ptr %sp, i64 1024

    %mem.0 = insertvalue %Mem undef, %Sp %sp, 0
    %mem.1 = insertvalue %Mem %mem.0, %Base %sp, 1
    %mem.2 = insertvalue %Mem %mem.1, %Limit %limit, 2

    ret %Mem %mem.2
}

define %Stk @newStack() alwaysinline {

    ; TODO find actual size of stack
    %stk = call ptr @malloc(i64 112)

    ; TODO initialize to zero and grow later
    %stackmem = call %Mem @newMem()

    %stk.0 = insertvalue %StkVal undef, %Rc 0, 0
    %stk.1 = insertvalue %StkVal %stk.0, %Mem %stackmem, 1
    %stk.2 = insertvalue %StkVal %stk.1, %Region zeroinitializer, 2
    %stk.3 = insertvalue %StkVal %stk.2, %Stk null, 3

    store %StkVal %stk.3, %Stk %stk

    ret %Stk %stk
}

define %Sp @pushStack(%Stk %stk, %Sp %oldsp) alwaysinline {
    %newstk.0 = load %StkVal, %Stk %stk
    %newstk = insertvalue %StkVal %newstk.0, %Stk %stk, 3

    %oldstk = call %StkVal @getStk(%Sp %oldsp)

    call void @setStk(%StkVal %newstk)

    store %StkVal %oldstk, %Stk %stk

    %newsp = extractvalue %StkVal %newstk, 1, 0
    ret %Sp %newsp
}

define {%Stk, %Sp} @popStack(%Sp %oldsp) alwaysinline {

    %oldstk = call %StkVal @getStk(%Sp %oldsp)

    %rest = extractvalue %StkVal %oldstk, 3
    %newstk = load %StkVal, %Stk %rest

    call void @setStk(%StkVal %newstk)

    store %StkVal %oldstk, %Stk %rest

    %newsp = extractvalue %StkVal %newstk, 1, 0
    %ret.0 = insertvalue {%Stk, %Sp} undef, %Stk %rest, 0
    %ret.1 = insertvalue {%Stk, %Sp} %ret.0, %Sp %newsp, 1

    ret {%Stk, %Sp} %ret.1
}

define %Sp @underflowStack(%Sp %sp) alwaysinline {
    %stk = load %Stk, ptr @rest
    %newstk = load %StkVal, %Stk %stk

    %region = load %Region, ptr @region
    call void @eraseRegion(%Region %region)

    call void @setStk(%StkVal %newstk)

    call void @free(%Sp %sp)
    call void @free(%Stk %stk)

    %newsp = extractvalue %StkVal %newstk, 1, 0
    ret %Sp %newsp
}

define %Mem @copyMem(%Mem %mem) alwaysinline {
    %sp = extractvalue %Mem %mem, 0
    %base = extractvalue %Mem %mem, 1
    %limit = extractvalue %Mem %mem, 2

    %intsp = ptrtoint %Sp %sp to i64
    %intbase = ptrtoint %Base %base to i64
    %intlimit = ptrtoint %Limit %limit to i64
    %used = sub i64 %intsp, %intbase
    %size = sub i64 %intlimit, %intbase

    %newbase = call ptr @malloc(i64 %size)
    %intnewbase = ptrtoint %Base %newbase to i64
    %intnewsp = add i64 %intnewbase, %used
    %intnewlimit = add i64 %intnewbase, %size
    %newsp = inttoptr i64 %intnewsp to %Sp
    %newlimit = inttoptr i64 %intnewlimit to %Limit

    call void @memcpy(ptr %newbase, ptr %base, i64 %used)

    %mem.0 = insertvalue %Mem undef, %Sp %newsp, 0
    %mem.1 = insertvalue %Mem %mem.0, %Base %newbase, 1
    %mem.2 = insertvalue %Mem %mem.1, %Limit %newlimit, 2

    ret %Mem %mem.2
}

define %Region @copyRegion(%Region %region) alwaysinline {
    %mem.0 = extractvalue %Region %region, 0
    %mem.1 = extractvalue %Region %region, 1
    %mem.2 = extractvalue %Region %region, 2

    %objectsbase = extractvalue %Region %region, 1, 1
    %objectssp = extractvalue %Region %region, 1, 0
    call void @forEachObject(%Base %objectsbase, %Sp %objectssp, %Eraser @sharePositive)

    %stringsbase = extractvalue %Region %region, 2, 1
    %stringssp = extractvalue %Region %region, 2, 0
    call void @forEachObject(%Base %stringsbase, %Sp %stringssp, %Eraser @c_buffer_refcount_increment)

    %newmem.0 = call %Mem @copyMem(%Mem %mem.0)
    %newmem.1 = call %Mem @copyMem(%Mem %mem.1)
    %newmem.2 = call %Mem @copyMem(%Mem %mem.2)

    %region.0 = insertvalue %Region undef, %Mem %newmem.0, 0
    %region.1 = insertvalue %Region %region.0, %Mem %newmem.1, 1
    %region.2 = insertvalue %Region %region.1, %Mem %newmem.2, 2

    ret %Region %region.2
}

define %Stk @uniqueStack(%Stk %stk) alwaysinline {

entry:
    %stkrc = getelementptr %StkVal, %Stk %stk, i64 0, i32 0
    %rc = load %Rc, ptr %stkrc
    switch %Rc %rc, label %copy [%Rc 0, label %done]

done:
    ret %Stk %stk

copy:
    %stkmem = getelementptr %StkVal, %Stk %stk, i64 0, i32 1
    %stkregion = getelementptr %StkVal, %Stk %stk, i64 0, i32 2
    %stkrest = getelementptr %StkVal, %Stk %stk, i64 0, i32 3

    %mem = load %Mem, ptr %stkmem
    %region = load %Region, ptr %stkregion
    %rest = load %Stk, ptr %stkrest

    %newstk = call ptr @malloc(i64 112)
    %newstkrc = getelementptr %StkVal, %Stk %newstk, i64 0, i32 0
    %newstkmem = getelementptr %StkVal, %Stk %newstk, i64 0, i32 1
    %newstkregion = getelementptr %StkVal, %Stk %newstk, i64 0, i32 2
    %newstkrest = getelementptr %StkVal, %Stk %newstk, i64 0, i32 3

    %newmem = call %Mem @copyMem(%Mem %mem)

    %newsp = extractvalue %Mem %newmem, 0
    call fastcc void @shareFrames(%Sp %newsp)

    %newregion = call %Region @copyRegion(%Region %region)

    store %Rc 0, ptr %newstkrc
    store %Mem %newmem, ptr %newstkmem
    store %Region %newregion, ptr %newstkregion
    store %Stk null, ptr %newstkrest

    %newoldrc = sub %Rc %rc, 1
    store %Rc %newoldrc, ptr %stkrc

    ret %Stk %newstk
}

define void @shareStack(%Stk %stk) alwaysinline {
    %stkrc = getelementptr %StkVal, %Stk %stk, i64 0, i32 0
    %rc = load %Rc, ptr %stkrc
    %rc.1 = add %Rc %rc, 1
    store %Rc %rc.1, ptr %stkrc
    ret void
}

define void @eraseStack(%Stk %stk) alwaysinline {
    %stkrc = getelementptr %StkVal, %Stk %stk, i64 0, i32 0
    %rc = load %Rc, ptr %stkrc
    switch %Rc %rc, label %decr [%Rc 0, label %free]

    decr:
    %rc.1 = sub %Rc %rc, 1
    store %Rc %rc.1, ptr %stkrc
    ret void

    free:
    %stksp = getelementptr %StkVal, %Stk %stk, i64 0, i32 1, i32 0
    %sp = load %Sp, ptr %stksp
    call fastcc void @eraseFrames(%Sp %sp)

    %regionp = getelementptr %StkVal, %Stk %stk, i64 0, i32 2
    %region = load %Region, ptr %regionp

    call void @eraseRegion(%Region %region)

    call void @free(%Stk %stk)
    ret void
}

define fastcc void @shareFrames(%Sp %sp) alwaysinline {
    %newsp = getelementptr %FrameHeader, %Sp %sp, i64 -1
    %stksharer = getelementptr %FrameHeader, %Sp %newsp, i64 0, i32 1
    %sharer = load %Sharer, ptr %stksharer
    tail call fastcc void %sharer(%Sp %newsp)
    ret void
}

define fastcc void @eraseFrames(%Sp %sp) alwaysinline {
    %newsp = getelementptr %FrameHeader, %Sp %sp, i64 -1
    %stkeraser = getelementptr %FrameHeader, %Sp %newsp, i64 0, i32 2
    %eraser = load %Eraser, ptr %stkeraser
    tail call fastcc void %eraser(%Sp %newsp)
    ret void
}

define void @forEachObject(ptr %elementp, ptr %end, ptr %f) alwaysinline {
    %done = icmp uge ptr %elementp, %end
    br i1 %done, label %return, label %erase

erase:
    %element = load %Pos, ptr %elementp
    call void %f(%Pos %element)

    %nextelementp = getelementptr %Pos, ptr %elementp, i64 1
    tail call void @forEachObject(ptr %nextelementp, ptr %end, ptr %f)
    ret void

return:
    ret void
}

define void @eraseRegion(%Region %region) alwaysinline {
    %valuesbase = extractvalue %Region %region, 0, 1
    call void @free(%Base %valuesbase)

    %objectsbase = extractvalue %Region %region, 1, 1
    %objectssp = extractvalue %Region %region, 1, 0
    call void @forEachObject(%Base %objectsbase, %Sp %objectssp, %Eraser @erasePositive)
    call void @free(%Base %objectsbase)

    %stringsbase = extractvalue %Region %region, 2, 1
    %stringssp = extractvalue %Region %region, 2, 0
    call void @forEachObject(%Base %stringsbase, %Sp %stringssp, %Eraser @c_buffer_refcount_decrement)
    call void @free(%Base %stringsbase)

    ret void
}

; RTS initialization

define fastcc void @topLevel(%Env %env, %Sp noalias %sp) {
    %base = load %Base, ptr @base
    call void @free(%Base %base)

    %region = load %Region, ptr @region
    %base.0 = extractvalue %Region %region, 0, 1
    %base.1 = extractvalue %Region %region, 1, 1
    %base.2 = extractvalue %Region %region, 2, 1

    call void @free(%Base %base.0)
    call void @free(%Base %base.1)
    call void @free(%Base %base.2)

    call void @free(%Env %env)
    ret void
}

define fastcc void @topLevelSharer(%Env %env) {
    ; TODO this should never be called
    ret void
}

define fastcc void @topLevelEraser(%Env %env) {
    ; TODO this should never be called
    ret void
}

; Primitive Types

%Int = type i64
%Double = type double

%Evi = type i64
