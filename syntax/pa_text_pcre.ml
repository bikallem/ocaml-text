(*
 * pa_text_pcre.ml
 * ---------------
 * Copyright : (c) 2010, Jeremie Dimino <jeremie@dimino.org>
 * Licence   : BSD3
 *
 * This file is a part of ocaml-text.
 *)

open Camlp4.PreCast
open Syntax

let lookup tbl key =
  try
    Some(Hashtbl.find tbl key)
  with
      Not_found -> None

(* +-----------------------------------------------------------------+
   | Regular expression AST                                          |
   +-----------------------------------------------------------------+ *)

type converter =
  | Constant of Ast.expr
  | Function of Ast.expr
  | Position

type regexp =
  | Nil of Ast.loc
  | Literal of Ast.loc * string
  | Any of Ast.loc
  | Repeat of Ast.loc * regexp * int (* minimum *) * int option (* maximum *)
  | Concat of Ast.loc * regexp * regexp
  | Alternative of Ast.loc * regexp * regexp
  | Bind of Ast.loc * regexp * string * converter option
  | Alias of Ast.loc * string

let star loc regexp = Repeat(loc, regexp, 0, None)
let plus loc regexp = Repeat(loc, regexp, 1, None)
let opt loc regexp = Repeat(loc, regexp, 0, Some 1)

let loc_of_regexp = function
  | Nil l -> l
  | Literal(l, _) -> l
  | Any l -> l
  | Repeat(l, _, _, _) -> l
  | Concat(l, _, _) -> l
  | Alternative(l, _, _) -> l
  | Bind(l, _, _, _) -> l
  | Alias(l, _) -> l

(* +-----------------------------------------------------------------+
   | Regular expression parsing                                      |
   +-----------------------------------------------------------------+ *)

let regexp_eoi = Gram.Entry.mk "regexp_eoi"

EXTEND Gram
  GLOBAL: regexp_eoi;

  utf8_string:
    [ [ s = STRING ->
          match Text.check s with
            | Some error ->
                Loc.raise _loc (Failure("invalid UTF-8 string: " ^ error))
            | None ->
                s ] ];

  range:
    [ [ a = INT ->
          let a = int_of_string a in
          if a < 0 then
            Loc.raise _loc (Failure "range bounds must be positive number")
          else
            (a, Some a)
      | a = INT; "-"; b = INT ->
          let a = int_of_string a and b = int_of_string b in
          if a < 0 || b < a then
            Loc.raise _loc (Failure "invalid range bounds")
          else
            (a, Some b)
      | a = INT; "+" ->
          let a = int_of_string a in
          if a < 0 then
            Loc.raise _loc (Failure "range bounds must be positive number")
          else
            (a, None) ] ];

  regexp:
    [ [ r = SELF; "as"; i = LIDENT;
        conv =
          OPT [ ":"; s = LIDENT -> Function <:expr< $lid: s ^ "_of_string"$ >>
              | ":="; e = expr -> Function e
              | "="; e = expr -> Constant e ] ->
            Bind(_loc, r, i, conv)
      | r1 = SELF; "|"; r2 = SELF -> Alternative(_loc, r1, r2)
      | r1 = SELF; r2 = SELF -> Concat(_loc, r1, r2) ]

    | "postop" NONA
        [ r = SELF; "*" -> star _loc r
        | r = SELF; "+" -> plus _loc r
        | r = SELF; "?" -> opt _loc r
        | r = SELF; "{"; (a, b) = range; "}" -> Repeat(_loc, r, a, b) ]

    | "simple" NONA
        [ s = utf8_string -> Literal(_loc, s)
        | "_" -> Any _loc
        | i = LIDENT -> Alias(_loc, i)
        | "^" -> Alias(_loc, "^")
        | "$" -> Alias(_loc, "$")
        | "%"; name = LIDENT -> Bind(_loc, Nil _loc, name, Some Position)
        | "("; r = SELF; ")" -> r ] ];

  regexp_eoi:
    [ [ re = regexp; `EOI -> re ] ];
END

(* +-----------------------------------------------------------------+
   | AST --> pcre regular expressions                                |
   +-----------------------------------------------------------------+ *)

let string_of_regexp ast =
  let buffer = Buffer.create 42 in
  let rec loop = function
    | Nil _ ->
        ()
    | Literal(_, lit) ->
        Buffer.add_string buffer lit
    | Any _ ->
        Buffer.add_char buffer '.'
    | Repeat(_, r, 0, None) ->
        loop r;
        Buffer.add_char buffer '*'
    | Repeat(_, r, 1, None) ->
        loop r;
        Buffer.add_char buffer '+'
    | Repeat(_, r, 0, Some 1) ->
        loop r;
        Buffer.add_char buffer '?'
    | Repeat(_, r, min, None) ->
        loop r;
        Printf.bprintf buffer "{%d+}" min
    | Repeat(_, r, min, Some max) when min = max ->
        loop r;
        Printf.bprintf buffer "{%d}" min
    | Repeat(_, r, min, Some max) ->
        loop r;
        Printf.bprintf buffer "{%d-%d}" min max
    | Concat(_, r1, r2) ->
        loop r1;
        loop r2
    | Alternative(_, r1, r2) ->
        loop r1;
        Buffer.add_char buffer '|';
        loop r2
    | Bind(_, r, i, c) ->
        Buffer.add_char buffer '(';
        loop r;
        Buffer.add_char buffer ')'
    | Alias(_, "^") ->
        Buffer.add_char buffer '^'
    | Alias(_, "$") ->
        Buffer.add_char buffer '$'
    | Alias(_, i) ->
        assert false
  in
  loop ast;
  Buffer.contents buffer

(* +-----------------------------------------------------------------+
   | Regular expressions processing                                  |
   +-----------------------------------------------------------------+ *)

(* Return the list of bounded variables with their group number *)
let collect_regexp_bindings ast =
  let rec loop n acc = function
    | Nil _ | Literal _| Any _ | Alias _->
        (n, acc)
    | Repeat(_, r, _, _) ->
        loop n acc r
    | Concat(_, r1, r2) ->
        let n, acc = loop n acc r1 in
        loop n acc r2
    | Alternative(l, r1, r2) ->
        let n, acc = loop n acc r1 in
        loop n acc r2
    | Bind(_loc, r, id, conv) ->
        loop (n + 1) ((_loc, id, n, conv) :: acc) r
  in
  snd (loop 1 [] ast)

(* +-----------------------------------------------------------------+
   | Quotation expansion                                             |
   +-----------------------------------------------------------------+ *)

let prefix = "__pa_text_pcre_"

(* Mapping from unique identifier of the form [__pa_text_pcre_NNN] to
   its corresponding regular expression ast *)
let regexps : (string, regexp) Hashtbl.t = Hashtbl.create 42

let gen_id =
  let nb = ref 0 in
  fun () ->
    let x = !nb in
    nb := x + 1;
    prefix ^ string_of_int x

let expand_regexp _loc _loc_name_opt quotation_contents =
  let ast = Gram.parse_string regexp_eoi _loc quotation_contents in
  let id = gen_id () in
  Hashtbl.add regexps id ast;
  <:patt< $lid:id$ >>

(* +-----------------------------------------------------------------+
   | Code generation via ast filters                                 |
   +-----------------------------------------------------------------+ *)

type 'a collector = {
  prefix : string;
  mutable next_id : int;
  mutable collect : (Loc.t * string * 'a) list;
}

let collect collector _loc data =
  let id = Printf.sprintf "%s%s_%d" prefix collector.prefix collector.next_id in
  collector.next_id <- collector.next_id + 1;
  collector.collect <- (_loc, id, data) :: collector.collect;
  <:ident< $lid:id$ >>

(* Verify that [id] is an id generated by [gen_id] *)
let is_special_id id =
  let rec aux1 i =
    if i = String.length prefix then
      aux2 i
    else
      i < String.length id && id.[i] = prefix.[i] && aux1 (i + 1)
  and aux2 i =
    (i < String.length id) && match id.[i] with
      | '0' .. '9' -> aux3 (i + 1)
      | _ -> false
  and aux3 i =
    if i = String.length id then
      true
    else match id.[i] with
      | '0' .. '9' -> aux3 (i + 1)
      | _ -> false
  in
  aux1 0

(* Generate the expression for the given regular expression: *)
let gen_compile_regexp _loc regexp =
  <:expr< lazy(Text_pcre.regexp $str:string_of_regexp regexp$) >>

(* Collects all regular expressions in the pattern of a match case
   branch. [global_regexp_collector] collect all regular expression
   found in the toplevel expression, and [local_regexp_collector]
   collects all regular expression of the current branch. *)
class map_pattern global_regexp_collector local_regexp_collector = object
  inherit Ast.map as super

  method patt p = match super#patt p with
    | <:patt@_loc< $lid:id$ >> as p when is_special_id id -> begin
        match lookup regexps id with
          | Some regexp ->
              (* [regexp_id] is the variable which will appears at the toplevel: *)
              let regexp_id = collect global_regexp_collector _loc (gen_compile_regexp _loc regexp) in
              (* [capture_id] is the variable which will capture the string in the pattern: *)
              let capture_id = collect local_regexp_collector _loc (<:expr< $id:regexp_id$ >>, regexp) in
              <:patt< $id:capture_id$ >>
          | None ->
              p
      end
    | p ->
        p
end

module StringSet = Set.Make(String)

class collect_pattern_lids set = object
  inherit Ast.map as super

  method patt patt = match super#patt patt with
    | <:patt< $lid:id$ >> as patt ->
        set := StringSet.add id !set;
        patt
    | p ->
        patt
end

(* Check that all variables contained in variables are distincts *)
let check_collision patt variables =
  let add set (_loc, id, n, conv) =
    if StringSet.mem id set then
      Loc.raise _loc (Failure (Printf.sprintf "Variable %s is bound several times in this matching" id))
    else
      StringSet.add id set
  in
  let set = ref StringSet.empty in
  let _ = (new collect_pattern_lids set)#patt patt in
  let _ = List.fold_left (fun set vars -> List.fold_left add set vars) !set variables in
  ()

(* Maps all branch of the given match case. It returns [(b, mc)]
   where [b] is [true] iff at least one branch have been modified
   and [mc] is the result. *)
let rec map_match mapper global_regexp_collector = function
  | <:match_case@_loc< $patt$ when $cond$ -> $expr$ >> as mc ->
      let local_regexp_collector = { prefix = "var"; next_id = 0; collect = [] } in
      (* Map the pattern and collect regexp it contains *)
      let patt = (new map_pattern global_regexp_collector local_regexp_collector)#patt patt in
      if local_regexp_collector.collect = [] then
        (* If nothing has changed, keep the branch unchanged *)
        (false, mc)
      else
        let cond = mapper#expr cond and expr = mapper#expr expr in
        (* Generate the array [|(__pa_text_pcre_var_0, __pa_text_pcre_regexp_0); ... |] *)
        let arr = Ast.ExArr(_loc, Ast.exSem_of_list
                              (List.rev_map
                                 (fun (_loc, id, (expr, regexp)) -> <:expr< ($expr$, $lid:id$) >>)
                                 local_regexp_collector.collect)) in
        (* The when condition: *)
        let check_expr = <:expr< Text_pcre.exec __pa_text_pcre_result $arr$ >> in
        (* Merge the original condition with our new one: *)
        let cond = match cond with
          | <:expr< >> -> check_expr
          | _ -> <:expr< $cond$ && $check_expr$ >>
        in
        (* Collect all capture variables in regexps: *)
        let variables_by_regexp =
          List.map
            (fun (_loc, id, (expr, regexp)) -> (collect_regexp_bindings regexp))
            local_regexp_collector.collect
        in
        (* Check for conflicts *)
        check_collision patt variables_by_regexp;
        (* Bind pattern variables *)
        let rec make_bindings regexp_number acc = function
          | [] -> acc
          | variables :: rest ->
              let acc = List.fold_left begin fun acc (_loc, id, n, conv) ->
                let binding = match conv with
                  | None ->
                      <:binding< $lid:id$ = Pcre.get_substring
                                              (Array.unsafe_get !__pa_text_pcre_result $int:string_of_int regexp_number$)
                                              $int:string_of_int n$ >>
                  | Some(Constant e) ->
                      <:binding< $lid:id$ = $e$ >>
                  | Some(Function f) ->
                      <:binding< $lid:id$ = $f$ (Pcre.get_substring
                                                   (Array.unsafe_get !__pa_text_pcre_result $int:string_of_int regexp_number$)
                                                   $int:string_of_int n$) >>
                  | Some Position ->
                      <:binding< $lid:id$ = Pervasives.fst (Pcre.get_substring_ofs
                                                              (Array.unsafe_get !__pa_text_pcre_result $int:string_of_int regexp_number$)
                                                              $int:string_of_int n$) >>
                in
                binding :: acc
              end acc variables in
              make_bindings (regexp_number + 1) acc rest
        in
        (true, <:match_case< $patt$ when $cond$ -> let $Ast.biAnd_of_list (make_bindings 0 [] variables_by_regexp)$ in $expr$ >>)
  | <:match_case@_loc< $mc1$ | $mc2$ >> ->
      let (b1, mc1) = map_match mapper global_regexp_collector mc1
      and (b2, mc2) = map_match mapper global_regexp_collector mc2 in
      (b1 || b2, <:match_case< $mc1$ | $mc2$ >>)
  | mc ->
      (false, mc)

(* [global_regexp_collector] collects all regular expression found in the expression *)
class map global_regexp_collector = object(self)
  inherit Ast.map as super

  method expr expr = match super#expr expr with
    | <:expr@_loc< match $e$ with $mc$ >> as expr ->
        let modified, mc = map_match self global_regexp_collector mc in
        if modified then
          <:expr< let __pa_text_pcre_result = ref [||] in match $e$ with $mc$ >>
        else
          expr
    | <:expr@_loc< function $mc$ >> as expr ->
        let modified, mc = map_match self global_regexp_collector mc in
        if modified then
          <:expr< let __pa_text_pcre_result = ref [||] in function $mc$ >>
        else
          expr
    | expr ->
        expr
end

(* map expressions:

   [expr]

   becomes:

   {[
     let __pa_text_pcre_regexp_0 = lazy(Pcre.compile "....") in
     let __pa_text_pcre_regexp_1 = lazy(Pcre.compile "....") in
     ...
     let __pa_text_pcre_regexp_N = lazy(Pcre.compile "....") in
     expr
   ]}
*)
let map_expr e =
  let collector = { prefix = "regexp"; next_id = 0; collect = [] } in
  let e = (new map collector)#expr e in
  match collector.collect with
    | [] ->
        e
    | (_loc, id, expr) :: collect ->
        let binding =
          List.fold_left
            (fun acc (_loc, id, expr) -> <:binding< $acc$ and $lid:id$ = $expr$ >>)
            <:binding< $lid:id$ = $expr$ >> collect
        in
        <:expr< let $binding$ in $e$ >>

(* Map class expresions:

   {[
     class class_expr
   ]}

   becomes:

   {[
     class
       let __pa_text_pcre_regexp_0 = lazy(Pcre.compile "....") in
       let __pa_text_pcre_regexp_1 = lazy(Pcre.compile "....") in
       ...
       let __pa_text_pcre_regexp_N = lazy(Pcre.compile "....") in
       class_expr
   ]}
*)
let map_class_expr e =
  let collector = { prefix = "regexp"; next_id = 0; collect = [] } in
  let e = (new map collector)#class_expr e in
  match collector.collect with
    | [] ->
        e
    | (_loc, id, expr) :: collect ->
        let binding =
          List.fold_left
            (fun acc (_loc, id, expr) -> <:binding< $acc$ and $lid:id$ = $expr$ >>)
            <:binding< $lid:id$ = $expr$ >> collect
        in
        <:class_expr< let $binding$ in $e$ >>

(* map let bindings:

   {[
     let id = expr
   ]}

   becomes:

   {[
     let id =
       let __pa_text_pcre_regexp_0 = lazy(Pcre.compile "....") in
       let __pa_text_pcre_regexp_1 = lazy(Pcre.compile "....") in
       ...
       let __pa_text_pcre_regexp_N = lazy(Pcre.compile "....") in
       expr
   ]}
*)
let rec map_binding = function
  | <:binding@_loc< $id$ = $e$ >> ->
      <:binding< $id$ = $map_expr e$ >>
  | <:binding@_loc< $a$ and $b$ >> ->
      <:binding< $map_binding a$ and $map_binding b$ >>
  | x ->
      x

(* Map top-level definitions *)
let map_def = function
  | Ast.StVal(loc, is_rec, binding) ->
      (* let id = expr *)
      Ast.StVal(loc, is_rec, map_binding binding)
  | Ast.StExp(loc, expr) ->
      (* expr *)
      Ast.StExp(loc, map_expr expr)
  | Ast.StCls(loc, ce) ->
      (* class class_expr *)
      Ast.StCls(loc, map_class_expr ce)
  | x ->
      x

(* +-----------------------------------------------------------------+
   | Registration                                                    |
   +-----------------------------------------------------------------+ *)

let () =
  Quotation.add "re" Quotation.DynAst.patt_tag expand_regexp
  let map = (Ast.map_str_item map_def)#str_item in
  AstFilters.register_str_item_filter map;
  AstFilters.register_topphrase_filter map