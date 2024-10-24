package effekt
package machine

import scala.collection.mutable
import effekt.context.Context
import effekt.lifted
import effekt.lifted.LiftInference
import effekt.symbols
import effekt.symbols.{ BlockSymbol, BlockType, DataType, ExternFunction, ExternType, FunctionType, Module, Name, Symbol, TermSymbol, UserFunction, ValueSymbol }
import effekt.symbols.builtins.TState

object Transformer {

  def transform(main: CoreTransformed, dependencies: List[CoreTransformed])(using C: Context): Program = {

    val mainSymbol = C.checkMain(main.mod)

    val Some(CoreLifted(_, _, _, liftedMain)) = LiftInference(main) : @unchecked

    // TODO this flatMap is wrong. If LiftInference returns None, then this will not fail but the dep. will be ignored.
    //   future me, or anybody else: if you fix this, also fix in ChezLift
    val liftedDeps = dependencies.flatMap { dep => LiftInference(dep).map(_.core) }

    C.using(module = main.mod) {
      transform(mainSymbol, liftedMain, liftedDeps);
    }
  }

  def transform(mainSymbol: TermSymbol, mod: lifted.ModuleDecl, deps: List[lifted.ModuleDecl])(using C: Context): Program = {
    val stmt = mod.defs;
    val mainName = transform(mainSymbol)
    given BC: BlocksParamsContext = BlocksParamsContext();

    findToplevelBlocksParams(stmt)
    val transformedMain = transformToplevel(stmt, Jump(Label(mainName, List())))

    var declarations: List[Declaration] = Nil

    // TODO Jonathan: I think this should be a foldRight here.
    val statement = deps.foldLeft(transformedMain) {
      case (compiled, dependency) =>
        declarations ++= dependency.externs.map(transform)
        findToplevelBlocksParams(dependency.defs)
        transformToplevel(dependency.defs, compiled)
    }

    declarations ++= mod.externs.map(transform)

    Program(declarations, statement)
  }


  // TODO this marks the end of the list
  //  mods match {
  //    case Nil =>
  //      Jump(Label(getMainName, List()))
  //    case lifted.ModuleDecl(_, _, stmt, _) :: mods =>
  //      findToplevelBlocksParams(stmt);
  //      transformToplevel(stmt, mods)
  //  }

  def transform(extern: lifted.Extern)(using BlocksParamsContext, Context): Declaration = extern match {
    case lifted.Extern.Def(name, functionType: FunctionType, params, body) =>
      val transformedParams = params.map {
        case lifted.ValueParam(id, tpe) => Variable(id.name.name, transform(tpe))
        case lifted.BlockParam(id, tpe) => Context.abort("Foreign functions currently cannot take block arguments.")
        case lifted.EvidenceParam(id) => Variable(id.name.name, builtins.Evidence)
      }
      Extern(transform(name), transformedParams, transform(functionType.result), body)

    case lifted.Extern.Include(contents) =>
      Include(contents)
  }

  def transformToplevel(stmt: lifted.Stmt, entryPoint: Statement)(using BlocksParamsContext, Context): Statement =
    stmt match {
      case lifted.Def(id, _, lifted.BlockLit(params, body), rest) =>
        Def(Label(transform(id), params.map(transform)), transform(body), transformToplevel(rest, entryPoint))

      case lifted.Return(lifted.UnitLit()) =>
        entryPoint

      case _ =>
        Context.abort(s"Unsupported declaration: $stmt")
    }

  def transform(stmt: lifted.Stmt)(using BlocksParamsContext, Context): Statement =
    stmt match {
      case lifted.Return(lifted.Run(stmt, tpe)) =>
        transform(stmt)

      case lifted.Return(expr) =>
        transform(expr).run { value => Return(List(value)) }

      case lifted.Val(id, tpe, bind, rest) =>
        PushFrame(
          Clause(List(transform(lifted.ValueParam(id, tpe))), transform(rest)),
            transform(bind)
        )

      case lifted.Let(id, tpe, binding, rest) =>
        transform(binding).run { value =>
          // TODO consider passing the environment to [[transform]] instead of explicit substitutions here.
          Substitute(List(Variable(transform(id), transform(tpe)) -> value), transform(rest))
        }

      case lifted.Def(id, tpe, block @ lifted.BlockLit(params, body), rest) =>
        // TODO does not work for mutually recursive local definitions
        val freeParams = lifted.freeVariables(block).toList.collect {
          case id: symbols.ValueSymbol => Variable(transform(id), transform(Context.valueTypeOf(id)))
          case id: symbols.BlockParam  => Variable(transform(id), transform(Context.blockTypeOf(id)))
          case id: symbols.ResumeParam => Variable(transform(id), transform(Context.blockTypeOf(id)))
          case id: lifted.EvidenceSymbol => Variable(transform(id), builtins.Evidence)
          // we ignore functions since we do not "close" over them.

          // TODO
          //          case id: lifted.ScopeId => ???
        }
        val allParams = params.map(transform) ++ freeParams;
        noteBlockParams(id, allParams)
        Def(Label(transform(id), allParams), transform(body), transform(rest))

      case lifted.Def(id, tpe, block @ lifted.New(impl), rest) =>
        // TODO freeParams?
        // TODO deal with evidenve?
        val symbols.InterfaceType(symbols.Interface(_, _, interfaceOps), _) = tpe : @unchecked
        val implTransformed = interfaceOps.map({ op =>
          impl.operations.find(_._1 == op).get
        }).map({
          case lifted.Operation(_, lifted.BlockLit(params, body)) =>
            // TODO we assume that there are no block params in methods
            Clause(params.map(transform), transform(body))
        })
        New(Variable(transform(id), transform(Context.blockTypeOf(id))), implTransformed, transform(rest))

      case lifted.App(lifted.BlockVar(id), List(), args) =>
        // TODO deal with BlockLit
        id match {
          case symbols.UserFunction(_, _, _, _, _, _, _)  | symbols.TmpBlock(_) =>
            // TODO this is a hack, values is in general shorter than environment
            val environment = getBlocksParams(id)
            transform(args).run { values =>
              // Here we actually need a substitution to prepare the environment for the jump
              Substitute(environment.zip(values), Jump(Label(transform(id), environment)))
            }
          case symbols.BlockParam(_, tpe) =>
            transform(args).run { values =>
              Invoke(Variable(transform(id), transform(tpe)), builtins.Apply, values)
            }
          case symbols.ResumeParam(_) =>
            // TODO currently only scoped resumptions are supported
            // TODO assuming first parameter is evidence TODO actually use evidence?
            transform(args).run { values =>
              val (evidence :: returnedValues) = values: @unchecked;
              PushStack(Variable(transform(id), Type.Stack()),
                Return(returnedValues))
            }
          case _ =>
            Context.abort(s"Unsupported blocksymbol: $id")
        }

      case lifted.App(lifted.Member(lifted.BlockVar(id), op), List(), args) =>
        val tpe = Context.blockTypeOf(id)
        val opTag = {
          tpe match
            case symbols.InterfaceType(symbols.Interface(_, _, ops), _) => ops.indexOf(op)
            case _ => Context.abort(s"Unsupported receiver type $tpe")
        }
        transform(args).run { values =>
          Invoke(Variable(transform(id), transform(tpe)), opTag, values)
        }

      case lifted.If(cond, thenStmt, elseStmt) =>
        transform(cond).run { value =>
          Switch(value, List(0 -> Clause(List(), transform(elseStmt)), 1 -> Clause(List(), transform(thenStmt))), None)
        }

      case lifted.Match(scrutinee, clauses, default) =>
        val transformedClauses = clauses.map { case (constr, lifted.BlockLit(params, body)) =>
          getTagFor(constr) -> Clause(params.map(transform), transform(body))
        }
        val transformedDefault = default.map { clause =>
          Clause(List(), transform(clause))
        }

        transform(scrutinee).run { value =>
          Switch(value, transformedClauses, transformedDefault)
        }

      case lifted.Try(lifted.BlockLit(List(ev, id), body), tpe, List(handler)) =>
        // TODO more than one handler
        val variable = Variable(freshName("a"), transform(tpe))
        val returnClause = Clause(List(variable), Return(List(variable)))
        val delimiter = Variable(freshName("returnClause"), Type.Stack())
        val regionVar = Variable(freshName("_"), Type.Region())

        LiteralEvidence(transform(ev), builtins.There,
          NewStack(delimiter, regionVar, returnClause,
            PushStack(delimiter,
              New(transform(id), transform(handler),
                transform(body)))))

      case lifted.Region(lifted.BlockLit(List(ev, id), body), tpe) =>
        val variable = Variable(freshName("a"), transform(tpe))
        val returnClause = Clause(List(variable), Return(List(variable)))
        val delimiter = Variable(freshName("returnClause"), Type.Stack())
        val regionVar = Variable(transform(id.id), Type.Region())

        LiteralEvidence(transform(ev), builtins.There,
          NewStack(delimiter, regionVar, returnClause,
            PushStack(delimiter, transform(body))))

      case lifted.State(id, init, region, body) =>
        transform(init).run { value =>
          val tpe = value.tpe;
          val name = transform(id)
          val variable = Variable(name, tpe)
          val stateVariable = Variable(name + "$State", Type.Reference(tpe))
          val loadVariable = Variable(freshName(name), tpe)
          val getter = Clause(List(),
                        Load(loadVariable, stateVariable,
                          Return(List(loadVariable))))

          val setterVariable = Variable(freshName(name), tpe)
          val setter = Clause(List(setterVariable),
                                Store(stateVariable, setterVariable,
                                  Return(List())))
          val regionVar = Variable(transform(region), Type.Region())

          // TODO use interface when it's implemented
          Allocate(stateVariable, value, regionVar,
            //New(variable, List(getter, setter),
              transform(body))
        }

      case _ =>
        Context.abort(s"Unsupported statement: $stmt")
    }

  def transform(arg: lifted.Argument)(using BlocksParamsContext, Context): Binding[Variable] = arg match {
    case expr: lifted.Expr => transform(expr)
    case block: lifted.Block => transform(block)
    case lifted.Evidence(scopes) => {
      scopes.map({ scope =>
        Variable(transform(scope), builtins.Evidence)
      }).foldRight({
        val res = Variable(freshName("ev_zero"), builtins.Evidence)
        Binding { k =>
          LiteralEvidence(res, builtins.Here, k(res))
        }: Binding[Variable]
      })({(evi, acc) =>
        val res = Variable(freshName("ev_acc"), builtins.Evidence)
        acc.flatMap({accV => Binding { k =>
          ComposeEvidence(res, evi, accV, k(res))
        }})
      })
    }
  }

  def transform(block: lifted.Block)(using BlocksParamsContext, Context): Binding[Variable] = block match {
    case lifted.BlockVar(id) =>
      val tpe = Context.blockTypeOf(id)
      pure(Variable(transform(id), transform(tpe)))

    case lifted.BlockLit(params, body) =>
      val parameters = params.map(transform);
      val variable = Variable(freshName("g"), Negative("<function>"))
      Binding { k =>
        New(variable, List(Clause(parameters, transform(body))), k(variable))
      }

    case lifted.Member(b, field) => ???
    case lifted.Unbox(e) => ???
    case lifted.New(impl) => ???
  }

  def transform(expr: lifted.Expr)(using BlocksParamsContext, Context): Binding[Variable] = expr match {
    case lifted.ValueVar(id) =>
      val tpe = Context.valueTypeOf(id);
      pure(Variable(transform(id), transform(tpe)))

    case lifted.UnitLit() =>
      val variable = Variable(freshName("x"), Positive("Unit"));
      Binding { k =>
        Construct(variable, builtins.Unit, List(), k(variable))
      }

    case lifted.IntLit(value) =>
      val variable = Variable(freshName("x"), Type.Int());
      Binding { k =>
        LiteralInt(variable, value, k(variable))
      }

    case lifted.BooleanLit(value: Boolean) =>
      val variable = Variable(freshName("x"), Positive("Boolean"))
      Binding { k =>
        Construct(variable, if (value) builtins.True else builtins.False, List(), k(variable))
      }

    case lifted.DoubleLit(v) =>
      val literal_binding = Variable(freshName("x"), Type.Double());
      Binding { k =>
        LiteralDouble(literal_binding, v, k(literal_binding))
      }

    case lifted.StringLit(javastring) =>
      val literal_binding = Variable(freshName("utf8_string_literal"), Type.String());
      Binding { k =>
        LiteralUTF8String(literal_binding, javastring.getBytes("utf-8"), k(literal_binding))
      }

    // hardcoded translation for get and put.
    // TODO remove this when interfaces are correctly translated
    case lifted.PureApp(lifted.Member(lifted.BlockVar(x), TState.get), List(), List()) =>
      val tpe = transform(TState.extractType(Context.blockTypeOf(x)))
      val variable = Variable(freshName("x"), tpe)
      val stateVariable = Variable(transform(x) + "$State", Type.Reference(tpe))
      Binding { k =>
        Load(variable, stateVariable, k(variable))
      }

    case lifted.PureApp(lifted.Member(lifted.BlockVar(x), TState.put), List(), List(arg)) =>
      val tpe = transform(TState.extractType(Context.blockTypeOf(x)))
      val variable = Variable(freshName("x"), Positive("Unit"));
      val stateVariable = Variable(transform(x) + "$State", Type.Reference(tpe))
      transform(arg).flatMap { value =>
        Binding { k =>
          Store(stateVariable, value,
            Construct(variable, builtins.Unit, List(), k(variable)))
        }
      }

    case lifted.PureApp(lifted.BlockVar(blockName: symbols.ExternFunction), List(), args) =>
      val variable = Variable(freshName("x"), transform(blockName.result))
      transform(args).flatMap { values =>
        Binding { k =>
          ForeignCall(variable, transform(blockName), values, k(variable))
        }
      }

    case lifted.PureApp(lifted.BlockVar(blockName: symbols.Constructor), List(), args) =>
      val variable = Variable(freshName("x"), transform(blockName.returnType));
      val tag = getTagFor(blockName)

      transform(args).flatMap { values =>
        Binding { k =>
          Construct(variable, tag, values, k(variable))
        }
      }

    case lifted.Select(target, field: symbols.Field) =>
      val fields = field.constructor.fields
      val fieldIndex = fields.indexOf(field)
      val variables = fields.map { f => Variable(freshName("n"), transform(f.returnType)) }
      transform(target).flatMap { value =>
        Binding { k =>
          Switch(value, List(0 -> Clause(variables, k(variables(fieldIndex)))), None)
        }
      }

    case lifted.Run(stmt, tpe) =>
      // NOTE: `stmt` is guaranteed to be of type `tpe`.
      val variable = Variable(freshName("x"), transform(tpe))
      Binding { k =>
        PushFrame(Clause(List(variable), k(variable)), transform(stmt))
      }

    case _ =>
      Context.abort(s"Unsupported expression: $expr")
  }

  def getTagFor(constructor: symbols.Constructor)(using Context): Int = constructor.tpe match {
    case symbols.DataType(name, Nil, constructors) => constructors.indexOf(constructor)
    case symbols.DataType(name, tparams, constructors) => Context.abort("Not yet supported: (data) type polymorphism")
    case symbols.Record(name, Nil, constructor) => builtins.SingletonRecord
    case symbols.Record(name, tparams, constructor) => Context.abort("Not yet supported: (data) type polymorphism")
    case t @ symbols.ExternType(name, tparams) => Context.abort(s"Application to an unknown symbol: $t")
  }

  def transform(args: List[lifted.Argument])(using BlocksParamsContext, Context): Binding[List[Variable]] =
    args match {
      case Nil => pure(Nil)
      case arg :: args => transform(arg).flatMap { value => transform(args).flatMap { values => pure(value :: values) } }
    }

  def transform(handler: lifted.Implementation)(using BlocksParamsContext, Context): List[Clause] = {
    handler.operations.sortBy[Int]({
      case lifted.Operation(operationName, _) =>
        handler.id.ops.indexOf(operationName)
    }).map({
      case lifted.Operation(operationName, lifted.BlockLit(params :+ resume, body))=>
        // TODO we assume here that resume is the last param
        // TODO we assume that there are no block params in handlers
        // TODO we assume that evidence has to be passed as first param
        val ev = Variable(freshName("evidence"), builtins.Evidence)
        Clause(ev +: params.map(transform),
          PopStacks(Variable(transform(resume).name, Type.Stack()), ev,
            transform(body)))
      case _ =>
        Context.abort(s"Unsupported handler $handler")
    })
  }

  def transform(param: lifted.Param)(using Context): Variable =
    param match {
      case lifted.ValueParam(name, tpe) =>
        Variable(transform(name), transform(tpe))
      case lifted.BlockParam(name, tpe) =>
        Variable(transform(name), transform(tpe))
      case lifted.EvidenceParam(name) =>
        Variable(transform(name), builtins.Evidence)
    }

  def transform(tpe: symbols.Type)(using Context): Type = tpe match {

    case symbols.builtins.TUnit => builtins.UnitType

    case symbols.builtins.TInt => Type.Int()

    case symbols.builtins.TBoolean => builtins.BooleanType

    case symbols.builtins.TDouble => Type.Double()

    case symbols.builtins.TString => Type.String()

    case symbols.FunctionType(Nil, _, vparams, Nil, _, _) => Negative("<function>")

    case symbols.InterfaceType(interface, List()) => Negative(interface.name.name)

    case symbols.ValueTypeApp(typeConstructor, List()) => Positive(typeConstructor.name.name)

    case _ =>
      Context.abort(s"unsupported type: $tpe (class = ${tpe.getClass})")
  }

  def transform(id: Symbol): String =
    s"${id.name}_${id.id}"

  def freshName(baseName: String): String = baseName + "_" + symbols.Symbol.fresh.next()

  def findToplevelBlocksParams(stmt: lifted.Stmt)(using BlocksParamsContext, Context): Unit = {
    stmt match {
      case lifted.Def(blockName, _, lifted.BlockLit(params, body), rest) =>
        noteBlockParams(blockName, params.map(transform));
        findToplevelBlocksParams(rest)

      case lifted.Def(_, _, _, rest) =>
        // TODO expand this catch-all case
        findToplevelBlocksParams(rest)
      case lifted.Return(lifted.UnitLit()) =>
        ()
      case _ =>
        println("unsupported in finding toplevel blocks " + stmt)
        ()
    }
  }

  /**
   * Extra info in context
   */

  def abort(message: String)(using C: Context) =
    C.abort(message)

  class BlocksParamsContext() {
    var blocksParams: Map[BlockSymbol, Environment] = Map()
  }

  def noteBlockParams(id: BlockSymbol, params: Environment)(using BC: BlocksParamsContext): Unit = {
    BC.blocksParams = BC.blocksParams + (id -> params)
  }

  def getBlocksParams(id: BlockSymbol)(using BC: BlocksParamsContext): Environment = {
    // TODO what if this is not found?
    BC.blocksParams(id)
  }

  case class Binding[A](run: (A => Statement) => Statement) {
    def flatMap[B](rest: A => Binding[B]): Binding[B] = {
      Binding(k => run(a => rest(a).run(k)))
    }
  }

  def pure[A](a: A): Binding[A] = Binding(k => k(a))


  def Context(using C: Context) = C
}
