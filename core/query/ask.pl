:- module(ask,[
              ask/2,
              ask_ast/3,
              create_context/2,
              create_context/3,
              collection_descriptor_prefixes/2,
              context_overriding_prefixes/3
          ]).

/** <module> Ask
 *
 * Prolog interface to ask queries
 *
 * * * * * * * * * * * * * COPYRIGHT NOTICE  * * * * * * * * * * * * * * *
 *                                                                       *
 *  This file is part of TerminusDB.                                     *
 *                                                                       *
 *  TerminusDB is free software: you can redistribute it and/or modify   *
 *  it under the terms of the GNU General Public License as published by *
 *  the Free Software Foundation, under version 3 of the License.        *
 *                                                                       *
 *                                                                       *
 *  TerminusDB is distributed in the hope that it will be useful,        *
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of       *
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the        *
 *  GNU General Public License for more details.                         *
 *                                                                       *
 *  You should have received a copy of the GNU General Public License    *
 *  along with TerminusDB.  If not, see <https://www.gnu.org/licenses/>. *
 *                                                                       *
 * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * * */

:- reexport(core(util/syntax)).
:- use_module(woql_compile).
:- use_module(global_prefixes).

:- use_module(core(util)).
:- use_module(core(triple)).
:- use_module(core(transaction)).

/**
 * pre_term_to_term_and_bindings(Pre_Term, Woql_Term, Bindings_In, Bindings_Out) is det.
 *
 * Pre term has free variables that need to be changed into woql variables witha binding
 */
pre_term_to_term_and_bindings(Ctx,Pre_Term,Term,Bindings_In,Bindings_Out) :-
    (   var(Pre_Term)
    ->  (   lookup_backwards(Pre_Term,V,Bindings_In)
        ->  Bindings_In = Bindings_Out,
            Term = v(V)
        ;   gensym('Var',G),
            Bindings_Out = [var_binding{ var_name : G,
                                         prolog_var: Pre_Term,
                                         woql_var : Woql_Var}|Bindings_In],
            freeze(Woql_Var,
                   (   Woql_Var = _@_
                   ->  Pre_Term = Woql_Var
                   ;   Woql_Var = Elt^^Type
                   ->  freeze(Type,
                              (   uri_to_prefixed(Type,Ctx,Prefixed_Type),
                                  Pre_Term = Elt^^Prefixed_Type))
                   ;   uri_to_prefixed(Woql_Var,Ctx,Pre_Term))),
            Term = v(G)
        )
    ;   is_dict(Pre_Term)
    ->  Term = Pre_Term,
        Bindings_In=Bindings_Out
    ;   Pre_Term =.. [F|Args],
        mapm(pre_term_to_term_and_bindings(Ctx),Args,New_Args,Bindings_In,Bindings_Out),
        Term =.. [F|New_Args]
    ).

collection_descriptor_prefixes_(Descriptor, Prefixes) :-
    terminus_descriptor{} :< Descriptor,
    !,
    Prefixes = _{doc: 'terminus:///terminus/document/'}.
collection_descriptor_prefixes_(Descriptor, Prefixes) :-
    id_descriptor{} :< Descriptor,
    !,
    Prefixes = _{}.
collection_descriptor_prefixes_(Descriptor, Prefixes) :-
    label_descriptor{label: Label} :< Descriptor,
    !,
    atomic_list_concat(['terminus:///',Label,'/document/'], Doc_Prefix),
    Prefixes = _{doc: Doc_Prefix}.
collection_descriptor_prefixes_(Descriptor, Prefixes) :-
    database_descriptor{
        database_name: Name
    } :< Descriptor,
    !,
    atomic_list_concat(['terminus:///',Name,'/document/'], Doc_Prefix),
    Prefixes = _{doc: Doc_Prefix}.
collection_descriptor_prefixes_(Descriptor, Prefixes) :-
    repository_descriptor{
        database_descriptor: Database_Descriptor
    } :< Descriptor,
    !,
    database_descriptor{
        database_name: Database_Name
    } :< Database_Descriptor,
    atomic_list_concat(['terminus:///', Database_Name, '/commits/document/'], Commit_Document_Prefix),
    Prefixes = _{doc : Commit_Document_Prefix}.
collection_descriptor_prefixes_(Descriptor, Prefixes) :-
    % Note: possible race condition.
    % We're querying the ref graph to find the branch base uri. it may have changed by the time we actually open the transaction.
    branch_descriptor{
        repository_descriptor: Repository_Descriptor,
        branch_name: Branch_Name
    } :< Descriptor,
    !,
    once(ask(Repository_Descriptor,
             (   t(Branch_URI, ref:branch_name, Branch_Name^^xsd:string),
                 t(Branch_URI, ref:branch_base_uri, Branch_Base_Uri^^xsd:anyURI)))),

    atomic_list_concat([Branch_Base_Uri, '/document/'], Document_Prefix),
    Prefixes = _{doc : Document_Prefix}.
collection_descriptor_prefixes_(Descriptor, Prefixes) :-
    % We don't know which documents you are retrieving
    % because we don't know the branch you are on,
    % and you can't write so it's up to you to set this
    % in the query.
    commit_descriptor{} :< Descriptor,
    !,
    Prefixes = _{}.

collection_descriptor_prefixes(Descriptor, Prefixes) :-
    default_prefixes(Default_Prefixes),
    collection_descriptor_prefixes_(Descriptor, Nondefault_Prefixes),
    merge_dictionaries(Nondefault_Prefixes, Default_Prefixes, Prefixes).

collection_descriptor_default_write_graph(terminus_descriptor{}, Graph_Descriptor) :-
    !,
    terminus_instance_name(Instance_Name),
    Graph_Descriptor = labelled_graph{
                           label : Instance_Name,
                           type : instance,
                           name : "main"
                       }.
collection_descriptor_default_write_graph(Descriptor, Graph_Descriptor) :-
    database_descriptor{ database_name : Name } = Descriptor,
    !,
    Graph_Descriptor = repo_graph{
                           database_name : Name,
                           type : instance,
                           name : "main"
                       }.
collection_descriptor_default_write_graph(Descriptor, Graph_Descriptor) :-
    repository_descriptor{
        database_descriptor : Database_Descriptor,
        repository_name : Repository_Name
    } = Descriptor,
    !,
    database_descriptor{ database_name : Database_Name } = Database_Descriptor,
    Graph_Descriptor = commit_graph{
                           database_name : Database_Name,
                           repository_name : Repository_Name,
                           type : instance,
                           name : "main"
                       }.
collection_descriptor_default_write_graph(Descriptor, Graph_Descriptor) :-
    branch_descriptor{ branch_name : Branch_Name,
                       repository_descriptor : Repository_Descriptor
                     } :< Descriptor,
    !,
    repository_descriptor{
        database_descriptor : Database_Descriptor,
        repository_name : Repository_Name
    } :< Repository_Descriptor,
    database_descriptor{
        database_name : Database_Name
    } :< Database_Descriptor,

    Graph_Descriptor = branch_graph{
                           database_name : Database_Name,
                           repository_name : Repository_Name,
                           branch_name : Branch_Name,
                           type : instance,
                           name : "main"
                       }.
collection_descriptor_default_write_graph(Descriptor, Graph_Descriptor) :-
    label_descriptor{ label: Label} :< Descriptor,
    !,
    text_to_string(Label, Label_String),
    Graph_Descriptor = labelled_graph{label:Label_String,
                                      type: instance,
                                      name:"main"
                                     }.
collection_descriptor_default_write_graph(_, empty).

create_context(Layer, Context) :-
    blob(Layer, layer),
    !,
    open_descriptor(Layer, Transaction),
    create_context(Transaction, Context).
create_context(Context, Context) :-
    query_context{} :< Context,
    !.
create_context(Transaction_Object, Context) :-
    transaction_object{ descriptor : Descriptor } :< Transaction_Object,
    !,
    collection_descriptor_prefixes(Descriptor, Prefixes),
    collection_descriptor_default_write_graph(Descriptor, Graph_Descriptor),

    Context = query_context{
        transaction_objects : [Transaction_Object],
        default_collection : Descriptor,
        filter : type_filter{ types : [instance] },
        prefixes : Prefixes,
        write_graph : Graph_Descriptor,
        bindings : [],
        selected : []
    }.
create_context(Descriptor, Context) :-
    open_descriptor(Descriptor, Transaction_Object),
    create_context(Transaction_Object, Context).

/**
 * create_context(Askable, Commit_Info, Context).
 *
 * Add Commit Info
 */
create_context(Askable, Commit_Info, Context) :-
    create_context(Askable, Context_Without_Commit),
    Context = Context_Without_Commit.put(commit_info, Commit_Info).



/**
 * empty_context(Context).
 *
 * Add Commit Info
 */
empty_context(Context) :-
    Context = query_context{
        transaction_objects : [],
        default_collection : empty,
        filter : type_filter{ types : [instance] },
        prefixes : _{},
        write_graph : empty,
        bindings : [],
        selected : [],
        authorization : empty
    }.

/*
 * context_overriding_prefixes(Context:query_context, Prefixes:prefixes,
 *                             New_Context:query_context) is det.
 *
 * Override the current query context with these prefixes when
 * there are collisions.
 */
context_overriding_prefixes(Context, Prefixes, New_Context) :-
    Query_Prefixes = Context.prefixes,
    merge_dictionaries(Prefixes,Query_Prefixes, New_Prefixes),
    New_Context = Context.put(prefixes, New_Prefixes).

/*
 * ask(+Transaction_Object, Pre_Term:Goal) is nondet.
 *
 * Ask a woql query
 */
ask(Askable, Pre_Term) :-
    create_context(Askable, Query_Context),

    pre_term_to_term_and_bindings(Query_Context.prefixes,
                                  Pre_Term,Term,
                                  [],Bindings_Out),
    New_Query_Ctx = Query_Context.put(bindings,Bindings_Out),

    ask_ast(New_Query_Ctx, Term, _).

ask_ast(Context, Ast, Bindings) :-
    compile_query(Ast,Prog, Context,Output),
    debug(terminus(sdk),'Program: ~q~n', [Prog]),

    woql_compile:Prog,

    Bindings = Output.bindings.