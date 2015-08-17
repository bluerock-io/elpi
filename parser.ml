(* elpi: embedded lambda prolog interpreter                                  *)
(* license: GNU Lesser General Public License Version 2.1                    *)
(* ------------------------------------------------------------------------- *)

module ASTFuncS = struct

  type t = string
  let compare = String.compare

  (* Hash consing *)
  let from_string =
   let h = Hashtbl.create 37 in
   function x ->
    try Hashtbl.find h x
    with Not_found -> Hashtbl.add h x x ; x

  let pp n = n
  let eq = (==)
  let truef = from_string "true"
  let andf = from_string ","
  let orf = from_string ";"
  let implf = from_string "=>"
  let rimplf = from_string ":-"
  let cutf = from_string "!"
  let pif = from_string "pi"
  let sigmaf = from_string "sigma"
  let eqf = from_string "="
  let isf = from_string "is"

end

type term =
   Const of ASTFuncS.t
 | Custom of ASTFuncS.t
 | App of term * term list
 | Lam of ASTFuncS.t * term
 | String of ASTFuncS.t
 | Int of int
 | Float of float

let mkLam x t = Lam (ASTFuncS.from_string x,t)
let mkNil = Const (ASTFuncS.from_string "nil")
let mkString str = String (ASTFuncS.from_string str)
let mkInt i = Int i
let mkFloat f = Float f
let mkSeq l =
 let rec aux =
  function
    [] -> assert false
  | [e] -> e
  | hd::tl -> App(Const (ASTFuncS.from_string "::"),[hd;aux tl])
 in
  aux l
let mkIs x f = App(Const ASTFuncS.isf,[x;f])

type fixity = Infixl | Infixr | Infix | Prefix | Postfix

let set_precedence,precedence_of =
 let module ConstMap = Map.Make(ASTFuncS) in 
 let precs = ref ConstMap.empty in
 (fun c p -> precs := ConstMap.add c p !precs),
 (fun c -> ConstMap.find c !precs)
;;

exception NotInProlog;;

type clause = term
type program = clause list
type goal = term

let mkApp =
 function
    App(c,l1)::l2 -> App(c,l1@l2)
  | (Custom _ | Const _) as c::l2 -> App(c,l2)
  | _ -> raise NotInProlog

let fresh_uv_names = ref (-1);;

let mkFreshUVar () = incr fresh_uv_names; Const (ASTFuncS.from_string ("_" ^ string_of_int !fresh_uv_names))
let mkCon c = Const (ASTFuncS.from_string c)
let mkCustom c = Custom (ASTFuncS.from_string c)

let parsed = ref [];;
let cur_dirname = ref ""

let rec symlink_dirname f =
  try
    let link = Unix.readlink f in
    if not(Filename.is_relative link) then symlink_dirname link
    else symlink_dirname Filename.(concat (dirname f) link)
  with Unix.Unix_error _ -> Filename.dirname f

let rec parse_one e filename =
 let filename =
   if not (Filename.is_relative filename) then filename
   else Filename.concat !cur_dirname filename in
 let prefixname = Filename.chop_extension filename in
 let filename =
  if Sys.file_exists filename then filename
  else if Filename.check_suffix filename ".elpi" then
   (* Backward compatibility with Teyjus *) 
   prefixname ^ ".mod"
  else if Filename.check_suffix filename ".mod" then
   (* Backward compatibility with Teyjus *) 
   prefixname ^ ".elpi"
  else raise (Failure ("file not found: " ^ filename)) in
 let inode = (Unix.stat filename).Unix.st_ino in
 if List.mem inode !parsed then begin
  Printf.eprintf "already loaded %s\n%!" filename;
  []
 end else begin
  let sigs =
   if Filename.check_suffix filename ".sig" then []
   else
    let signame = prefixname ^ ".sig" in
    if Sys.file_exists signame then parse_one e signame else [] in
  Printf.eprintf "loading %s\n%!" filename;
  parsed := inode::!parsed ;
  let ch = open_in filename in
  let saved_cur_dirname = !cur_dirname in
  cur_dirname := symlink_dirname filename;
  sigs @
  try
   let res = Grammar.Entry.parse e (Stream.of_channel ch) in
   close_in ch;
   cur_dirname := saved_cur_dirname;
   res
  with Ploc.Exc(l,(Token.Error msg | Stream.Error msg)) ->
    close_in ch;
    let last = Ploc.last_pos l in
    (*let ctx_len = 70 in CSC: TO BE FIXED AND RESTORED
    let ctx = "…"
      let start = max 0 (last - ctx_len) in
      let s = String.make 101 '\007' in
      let ch = open_in filename in
      (try really_input ch s 0 100 with End_of_file -> ());
      close_in ch;
      let last = String.index s '\007' in
      "…" ^ String.sub s start last ^ "…" in
    raise (Stream.Error(Printf.sprintf "%s\nnear: %s" msg ctx))*)
    raise (Stream.Error(Printf.sprintf "%s\nnear: %d" msg last))
  | Ploc.Exc(_,e) -> close_in ch; raise e
 end

let parse e filenames =
  List.concat (List.map (parse_one e) filenames)

let parse_string e s =
  try Grammar.Entry.parse e (Stream.of_string s)
  with Ploc.Exc(l,(Token.Error msg | Stream.Error msg)) ->
    let last = Ploc.last_pos l in
    let ctx_len = 70 in
    let ctx =
      let start = max 0 (last - ctx_len) in
      let len = min 100 (min (String.length s - start) last) in
      "…" ^ String.sub s start len ^ "…" in
    raise (Stream.Error(Printf.sprintf "%s\nnear: %s" msg ctx))
  | Ploc.Exc(_,e) -> raise e

let digit = lexer [ '0'-'9' ]
let octal = lexer [ '0'-'7' ]
let hex = lexer [ '0'-'9' | 'A'-'F' | 'a'-'f' ]
let schar2 =
 lexer [ '+'  | '*' | '/' | '^' | '<' | '>' | '`' | '\'' | '?' | '@' | '#'
       | '~' | '=' | '&' | '!' ]
let schar = lexer [ schar2 | '-' | '$' | '_' ]
let lcase = lexer [ 'a'-'z' ]
let ucase = lexer [ 'A'-'Z' ]
let idchar = lexer [ lcase | ucase | digit | schar ]
let rec idcharstar = lexer [ idchar idcharstar | ]
let idcharplus = lexer [ idchar idcharstar ]
let rec num = lexer [ digit | digit num ]

let rec string = lexer [ '"' | _ string ]

let constant = "CONSTANT" (* to use physical equality *)

let tok = lexer
  [ ucase idcharstar -> constant,$buf 
  | lcase idcharstar -> constant,$buf
  | schar2 idcharstar -> constant,$buf
  | '$' lcase idcharstar -> "BUILTIN",$buf
  | '$' idcharstar -> constant,$buf
  | num -> "INTEGER",$buf
  | num ?= [ '.' '0'-'9' ] '.' num -> "FLOAT",$buf
  | "->" -> "ARROW",$buf
  | "->" idcharplus -> constant,$buf
  | '-' idcharstar -> constant,$buf
  | '_' -> "FRESHUV", "_"
  | '_' idcharplus -> constant,$buf
  | ":-"  -> constant,$buf
  | ":"  -> "COLON",$buf
  | "::"  -> constant,$buf
  | ',' -> constant,$buf
  | ';' -> constant,$buf
  | '.' -> "FULLSTOP",$buf
  | '.' num -> "FLOAT",$buf
  | '\\' -> "BIND","\\"
  | '(' -> "LPAREN",$buf
  | ')' -> "RPAREN",$buf
  | '[' -> "LBRACKET",$buf
  | ']' -> "RBRACKET",$buf
  | '|' -> "PIPE",$buf
  | '"' string -> "LITERAL", let b = $buf in String.sub b 1 (String.length b-2)
]

let option_eq x y = match x, y with Some x, Some y -> x == y | _ -> x == y

module StringSet = Set.Make(String);;
let symbols = ref StringSet.empty;;

let rec lex c = parser bp
  | [< '( ' ' | '\n' | '\t' | '\r' ); s >] -> lex c s
  | [< '( '%' ); s >] -> comment c s
  | [< ?= [ '/'; '*' ]; '( '/' ); '( '*' ); s >] -> comment2 0 c s
  | [< s >] ep ->
       if option_eq (Stream.peek s) None then ("EOF",""), (bp, ep)
       else
        let (x,y) as res = tok c s in
        (if x == constant then
         (match y with
         | "module" -> "MODULE", "module"
         | "sig" -> "SIG", "SIG"
         | "import" -> "IMPORT", "accumulate"
         | "accum_sig" -> "ACCUM_SIG", "accum_sig"
         | "use_sig" -> "USE_SIG", "use_sig"
         | "local" -> "LOCAL", "local"
         | "localkind" -> "LOCALKIND", "localkind"
         | "useonly" -> "USEONLY", "useonly"
         | "exportdef" -> "EXPORTDEF", "exportdef"
         | "kind" -> "KIND", "kind"
         | "typeabbrev" -> "TYPEABBREV", "typeabbrev"
         | "type" -> "TYPE", "type"
         | "closed" -> "CLOSED", "closed"
        
         | "end" -> "EOF", "end"
         | "accumulate" -> "ACCUMULATE", "accumulate"
         | "infixl" -> "FIXITY", "infixl"
         | "infixr" -> "FIXITY", "infixr"
         | "infix" -> "FIXITY", "infix"
         | "prefix" -> "FIXITY", "prefix"
         | "prefixr" -> "FIXITY", "prefixr"
         | "postfix" -> "FIXITY", "postfix"
         | "postfixl" -> "FIXITY", "postfixl"
        
         | x when StringSet.mem x !symbols -> "SYMBOL",x
        
         | _ -> res) else res), (bp, ep)
and skip_to_dot c = parser
  | [< '( '.' ); s >] -> lex c s
  | [< '_ ; s >] -> skip_to_dot c s
and comment c = parser
  | [< '( '\n' ); s >] -> lex c s
  | [< '_ ; s >] -> comment c s
and comment2 lvl c = parser
  | [< ?= [ '*'; '/' ]; '( '*' ); '( '/'); s >] ->
      if lvl = 0 then lex c s else comment2 (lvl-1) c s
  | [< ?= [ '/'; '*' ]; '( '/' ); '( '*' ); s >] -> comment2 (lvl+1) c s
  | [< '_ ; s >] -> comment2 lvl c s


open Plexing

let lex_fun s =
  let tab = Hashtbl.create 207 in
  let last = ref Ploc.dummy in
  (Stream.from (fun id ->
     let tok, loc = lex Lexbuf.empty s in
     last := Ploc.make_unlined loc;
     Hashtbl.add tab id !last;
     Some tok)),
  (fun id -> try Hashtbl.find tab id with Not_found -> !last)

let tok_match =
 function
    ((s1:string),"") ->
      fun ((s2:string),v) ->
       if Pervasives.compare s1 s2 == 0 then v else raise Stream.Failure
  | ((s1:string),v1) ->
      fun ((s2:string),v2) ->
       if Pervasives.compare s1 s2==0 && Pervasives.compare v1 v2==0 then v2
       else raise Stream.Failure

let lex = {
  tok_func = lex_fun;
  tok_using =
   (fun x,y ->
      if x = "SYMBOL" && y <> "" then begin
       symbols := StringSet.add y !symbols
      end
   );
  tok_removing = (fun _ -> ());
  tok_match = tok_match;
  tok_text = (function (s,y) -> s ^ " " ^ y);
  tok_comm = None;
}

let g = Grammar.gcreate lex
let lp = Grammar.Entry.create g "lp"
let goal = Grammar.Entry.create g "goal"

let min_precedence = 0
let max_precedence = 256

let dummy_prod =
 let dummy_action =
   Gramext.action (fun _ ->
     failwith "internal error, lexer generated a dummy token") in
 [ [ Gramext.Stoken ("DUMMY", "") ], dummy_action ]

let used_precedences = ref [];;
let is_used n =
 let rec aux visited acc =
  function
     hd::_  when hd = n ->
     !used_precedences, (Gramext.Level (string_of_int n), None)
   | hd::tl when hd < n ->
     aux (hd::visited) (Gramext.After (string_of_int hd)) tl
   | l -> List.rev (n::visited) @ l, (acc, Some (string_of_int n))
 in
  let used, res = aux [] Gramext.First !used_precedences in
  used_precedences := used ;
  res
;;

EXTEND
  GLOBAL: lp goal;
  lp: [ [ cl = LIST0 clause; EOF -> List.concat cl ] ];
  const_sym:
    [[ c = CONSTANT -> c
     | s = SYMBOL -> s ]];
  clause :
    [[ f = atom; FULLSTOP -> [f]
     | MODULE; CONSTANT; FULLSTOP -> []
     | SIG; CONSTANT; FULLSTOP -> []
     | ACCUMULATE; filenames=LIST1 CONSTANT SEP SYMBOL ","; FULLSTOP ->
        parse lp (List.map (fun fn -> fn ^ ".mod") filenames)
     | IMPORT; LIST1 CONSTANT SEP SYMBOL ","; FULLSTOP -> []
     | ACCUM_SIG; filenames=LIST1 CONSTANT SEP SYMBOL ","; FULLSTOP ->
        parse lp (List.map (fun fn -> fn ^ ".sig") filenames)
     | USE_SIG; filenames=LIST1 CONSTANT SEP SYMBOL ","; FULLSTOP ->
        parse lp (List.map (fun fn -> fn ^ ".sig") filenames)
     | LOCAL; LIST1 const_sym SEP SYMBOL ","; FULLSTOP -> []
     | LOCAL; LIST1 const_sym SEP SYMBOL ","; type_; FULLSTOP -> []
     | LOCALKIND; LIST1 const_sym SEP SYMBOL ","; FULLSTOP -> []
     | LOCALKIND; LIST1 const_sym SEP SYMBOL ","; kind; FULLSTOP -> []
     | CLOSED; LIST1 const_sym SEP SYMBOL ","; FULLSTOP -> []
     | CLOSED; LIST1 const_sym SEP SYMBOL ","; type_; FULLSTOP -> []
     | USEONLY; LIST1 const_sym SEP SYMBOL ","; FULLSTOP -> []
     | USEONLY; LIST1 const_sym SEP SYMBOL ","; type_; FULLSTOP -> []
     | EXPORTDEF; LIST1 const_sym SEP SYMBOL ","; FULLSTOP -> []
     | EXPORTDEF; LIST1 const_sym SEP SYMBOL ","; type_; FULLSTOP -> []
     | TYPE; LIST1 const_sym SEP SYMBOL ","; type_; FULLSTOP -> []
     | KIND; LIST1 const_sym SEP SYMBOL ","; kind; FULLSTOP -> []
     | TYPEABBREV; abbrform; TYPE; FULLSTOP -> []
     | fix = FIXITY; syms = LIST1 const_sym SEP SYMBOL ","; prec = INTEGER; FULLSTOP ->
        let nprec = int_of_string prec in
        if nprec < min_precedence || nprec > max_precedence then
         assert false (* wrong precedence *)
        else
         let extend_one cst =
          let binrule =
           [ Gramext.Sself ; Gramext.Stoken ("SYMBOL",cst); Gramext.Sself ],
           Gramext.action (fun t2 cst t1 _ ->mkApp [mkCon cst;t1;t2]) in
          let prerule =
           [ Gramext.Stoken ("SYMBOL",cst); Gramext.Sself ],
           Gramext.action (fun t cst _ -> mkApp [mkCon cst;t]) in
          let postrule =
           [ Gramext.Sself ; Gramext.Stoken ("SYMBOL",cst) ],
           Gramext.action (fun cst t _ -> mkApp [mkCon cst;t]) in
          let fixity,rule,ppinfo =
           (* NOTE: we do not distinguish between infix and infixl,
              prefix and prefix, postfix and postfixl *)
           match fix with
             "infix"    -> Gramext.NonA,   binrule,  (Infix,nprec)
           | "infixl"   -> Gramext.LeftA,  binrule,  (Infixl,nprec)
           | "infixr"   -> Gramext.RightA, binrule,  (Infixr,nprec)
           | "prefix"   -> Gramext.NonA,   prerule,  (Prefix,nprec)
           | "prefixr"  -> Gramext.RightA, prerule,  (Prefix,nprec)
           | "postfix"  -> Gramext.NonA,   postrule, (Postfix,nprec)
           | "postfixl" -> Gramext.LeftA,  postrule, (Postfix,nprec)
           | _ -> assert false in
          set_precedence cst ppinfo ;
          let where,name = is_used nprec in
           Grammar.extend
            [Grammar.Entry.obj atom, Some where, [name, Some fixity, [rule]]];
         in
          List.iter extend_one syms ; 
          (* Debugging code
          prerr_endline "###########################################";
          Grammar.iter_entry (
            Grammar.print_entry Format.err_formatter
          ) (Grammar.Entry.obj atom);
          prerr_endline ""; *)
          []
    ]];
  kind:
    [[ TYPE -> ()
     | TYPE; ARROW; kind -> ()
    ]];
  type_:
    [[ ctype -> ()
     | ctype; ARROW; type_ -> ()
    ]];
  ctype:
    [[ CONSTANT -> ()
     | CONSTANT; LIST1 ctype -> ()
     | LPAREN; type_; RPAREN -> ()
    ]];
  abbrform:
    [[ CONSTANT -> ()
     | LPAREN; CONSTANT; LIST1 CONSTANT; RPAREN -> ()
     | LPAREN; abbrform; RPAREN -> ()
    ]];
  goal:
    [[ p = premise -> p ]];
  premise : [[ a = atom -> a ]];
  atom :
   [ "term"
      [ hd = atom; args = LIST1 atom LEVEL "abstterm" -> mkApp (hd::args) ]
   | "abstterm"
      [ c = CONSTANT; b = OPT [ BIND; a = atom LEVEL "0" -> a ] ->
          (match b with
              None -> mkCon c
            | Some b -> mkLam c b)
      | u = FRESHUV -> mkFreshUVar ()
      | s = LITERAL -> mkString s
      | s = INTEGER -> mkInt (int_of_string s) 
      | s = FLOAT -> mkFloat (float_of_string s) 
      | bt = BUILTIN -> mkCustom bt
      | LPAREN; a = atom; RPAREN -> a
        (* 120 is the first level after 110, which is that of , *)
      | LBRACKET; xs = LIST0 atom LEVEL "120" SEP SYMBOL ",";
          tl = OPT [ PIPE; x = atom LEVEL "0" -> x ]; RBRACKET ->
          let tl = match tl with None -> mkNil | Some x -> x in
          if List.length xs = 0 && tl <> mkNil then 
            raise (Token.Error ("List with no elements cannot have a tail"));
          if List.length xs = 0 then mkNil
          else mkSeq (xs@[tl]) ]];
END

let parse_program (*?(ontop=[])*) ~filenames : program =
  (* let insertions = parse plp s in
  let insert prog = function
    | item, (`Here | `End) -> prog @ [item]
    | item, `Begin -> item :: prog
    | (_,_,_,name as item), `Before n ->
        let newprog = List.fold_left (fun acc (_,_,_,cn as c) ->
          if CN.equal n cn then acc @ [item;c]
          else acc @ [c]) [] prog in
        if List.length prog = List.length newprog then
          raise (Stream.Error ("unable to insert clause "^CN.to_string name));
        newprog
    | (_,_,_,name as item), `After n ->
        let newprog = List.fold_left (fun acc (_,_,_,cn as c) ->
          if CN.equal n cn then acc @ [c;item]
          else acc @ [c]) [] prog in
        if List.length prog = List.length newprog then
          raise (Stream.Error ("unable to insert clause "^CN.to_string name));
        newprog in
  List.fold_left insert ontop insertions*)
  let execname = Unix.readlink "/proc/self/exe" in
  let pervasives = Filename.dirname execname ^ "/pervasives.elpi" in
  parse lp (pervasives::filenames)

let parse_goal s : goal = parse_string goal s

let parse_goal_from_stream strm =
  try Grammar.Entry.parse goal strm
  with
    Ploc.Exc(l,(Token.Error msg | Stream.Error msg)) -> raise(Stream.Error msg)
  | Ploc.Exc(_,e) -> raise e
