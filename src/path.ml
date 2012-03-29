(***********************************************************************)
(*                                                                     *)
(*    Copyright 2012 OCamlPro                                          *)
(*    Copyright 2012 INRIA                                             *)
(*                                                                     *)
(*  All rights reserved.  This file is distributed under the terms of  *)
(*  the GNU Public License version 3.0.                                *)
(*                                                                     *)
(*  TypeRex is distributed in the hope that it will be useful,         *)
(*  but WITHOUT ANY WARRANTY; without even the implied warranty of     *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the      *)
(*  GNU General Public License for more details.                       *)
(*                                                                     *)
(***********************************************************************)

open ExtList
open ExtString
open Namespace
open Uri

let log fmt =
  Globals.log "PATH" fmt

type url = {
  uri: uri option;
  hostname: string;
  port: int option;
}

let hostname_port hostname =
  try
    let u, p = BatString.split hostname ":" in
    u, Some (int_of_string p)
  with _ -> hostname, None

let url ?uri ?port hostname =
  let hostname = Run.normalize hostname in
  let hostname, port2 = hostname_port hostname in
  let uri, hostname = match uri with
    | None     -> uri_of_url hostname
    | Some uri -> Some uri, hostname in
  let port = match port, port2, uri with
    | Some p, _     , _
    | None  , Some p, _ -> Some p
    | _                 -> None in
  { uri; hostname; port }

let string_of_url url =
  let uri = match url.uri with
    | None   -> ""
    | Some u -> string_of_uri u in
  let port = match url.port with
    | None   -> ""
    | Some p -> ":" ^ string_of_int p in
  Printf.sprintf "%s%s%s" uri url.hostname port

type 'a ocaml_options = 
  | I of 'a

type raw_binary = 
  | Raw_binary of string (* contents *)

type raw_filename =
  | External of uri * string
  | Internal of string (* pointer to the local contents *)

type binary_data = 
  | Binary   of raw_binary
  | Filename of raw_filename

type links = {
  urls   : raw_filename list; (* list OR of archive to download *)
  patches: raw_filename list; (* list AND of patch to apply *)
}

type 'a archive = 
  | Archive of 'a
  | Links   of links 

type basename = B of string

(** Type used to represent an internal form of version, which is in
    particular not related to the version of a particular package *)
type internal_version = Version of string

type security_key = Random of string

let get_local_files = function
  | Internal p -> 
    if Filename.check_suffix p ".patch"
    || Filename.check_suffix p ".diff" then
      None
    else
      Some p 
  | _ -> None

module type RANDOM_KEY = sig
  val new_key : unit -> security_key
end

module Random_key : RANDOM_KEY = struct
  let make n = Random (String.implode (List.init n (fun _ -> char_of_int (Random.int 255))))

  let len = 128

  let n = ref (make len)

  let new_key _ = 
    let k = !n in
    let () = n := make len in
    k
end

module type PATH =
sig

  type t
  type filename

  type 'a contents = 
    | Directory of basename list
    | File of 'a
    | Not_found of string

  type 'a contents_rec = 
    | R_directory of (basename * 'a contents_rec) Enum.t
    | R_file of 'a
    | R_filename of filename list
    | R_lazy of (unit -> unit) (* The data describing the contents will appear as soon as : 
                                  1. the current directory is the directory where one would the contents appear,
                                  2. this function is executed. *)

  val init : string (* $HOME_OPAM *) -> t
  (* $HOME_OPAM_OVERSION = $HOME_OPAM/OVERSION *)

  (** definitions of some shortcuts *)

  (** the root of every path *)
  val root : filename (* ~/ *)

  val cwd : filename (* $PWD *)

  (** path in the packager filesystem, contains the collection of libraries and programs *)
  val package : t -> string (* computed from $PWD *) -> filename

  (** installed libraries for the package (at most one version installed) *)
  val lib : t -> name -> filename (* $HOME_OPAM_OVERSION/lib/NAME *)

  (** contain installed binaries *)
  val bin : t -> filename (* $HOME_OPAM_OVERSION/bin *)
  
  (** main configuration file *)
  val config : t -> filename (* $HOME_OPAM/config *)

  (** list of installed packages with their version *)
  val installed : t -> filename (* $HOME_OPAM_OVERSION/installed *)

  (** OPAM files considered for an arbitrary version and package *)
  val index : t -> name_version option -> filename (* $HOME_OPAM/index/NAME-VERSION.spec *)
  (* [None] : $HOME_OPAM/index *)

  val compil : t -> string -> filename
  (* $HOME_OPAM/compilers/[oversion].compil *)

  (** list of spec files *)
  val index_list : t -> name_version list (* [ $HOME_OPAM/index/NAME-VERSION.spec ] -> [ NAME, VERSION ] *)

  (** source archives for all versions of all packages *)
  val archives_targz : t -> name_version option -> filename (* $HOME_OPAM/archives/NAME-VERSION.tar.gz *)
  (* [None] : $HOME_OPAM/archives *)

  (** tempory folders used to decompress the corresponding archives *)
  val build : t -> name_version option -> filename (* $HOME_OPAM_OVERSION/build/NAME-VERSION *)
  (* [None] : $HOME_OPAM_OVERSION/build *)

  (** compiled files in the extracted archive to install *)
  (* XXX: P.install should be installed in their own path *)
  val to_install : t -> name_version -> filename (* $HOME_OPAM_OVERSION/build/NAME-VERSION/NAME.install *)

  (** package configuration for compile and link options *)
  (* XXX: P.config should be installed in their own path *)
  val pconfig : t -> name_version -> filename (* $HOME_OPAM_OVERSION/build/NAME-VERSION/NAME.config *)

  (** security keys related to package name *)
  val keys : t -> name -> filename (* $HOME_OPAM/keys/NAME *)

  (** similar as [keys] *)
  val hashes : t -> name -> filename (* $HOME_OPAM/hashes/NAME *)


  (** Path utilities **)

  (** Retrieves the contents from the hard disk. *)
  val find : filename -> binary_data contents

  (** see [find] *)
  val find_binary : filename -> raw_binary contents

  (** see [find] *)
  val find_filename : filename -> raw_filename contents

  (** Removes everything in [filename] if existed. *)
  val remove : filename -> unit

  (** Removes everything in [filename] if existed, then write [contents] instead. *)
  val add : filename -> binary_data contents -> unit

  (** Removes everything in [filename] if existed, then write [contents_rec] inside [filename]. *)
  val add_rec : filename -> binary_data contents_rec -> unit

  (** Returns the same meaning as [archive] but extracted in the right path (corresponding to name_version) . *)
  val extract : name_version -> raw_binary archive -> binary_data contents_rec

  (** Creates an archive entitled [string] 
      in the same directory as [filename] (which is also a directory). *)
  val to_archive : string (* archive name *) -> filename -> unit

  (** Executes an arbitrary list of command inside "build/NAME-VERSION". 
      For the [int], see [Sys.command]. 
      In particular, the execution continues as long as each command returns 0. *)
  val exec : t -> name_version -> string list -> int
  
  (** see [Filename.dirname] *)
  val dirname : filename -> filename

  (** see [Filename.basename] *)
  val basename : filename -> basename

  (** We iterate [Filename.chop_extension] on [basename] until a fix
      point is reached.  When [basename] is not of the form
      "NAME-VERSION", or when we can not extract the version, [string]
      is returned as version. *)
  val nv_of_extension : string (* version *) -> basename -> name * version

  (** see [Filename.concat] *)
  val concat : filename -> basename -> filename

  (** see [Sys.file_exists] *)
  val file_exists : filename -> bool

  (** [None] : not a directory *)
  val is_directory : filename -> raw_filename option

  (** Returns the exact path to give to the OCaml compiler (ie. -I ...) *)
  val ocaml_options_of_library : t -> name -> string ocaml_options 
  (* $HOME_OPAM/lib/NAME *)

  val string_of_filename: filename -> string

  val file_not_found: filename -> 'a

  val read: (filename -> 'a option) -> filename -> 'a
end

module Path : PATH = struct
  open Printf

  type filename = 
    | Normalized of string
    | Raw of string

  type t = { home : string
           ; home_ocamlversion : string }

  type 'a contents = 
    | Directory of basename list
    | File of 'a
    | Not_found of string

  type 'a contents_rec = 
    | R_directory of (basename * 'a contents_rec) Enum.t
    | R_file of 'a
    | R_filename of filename list
    | R_lazy of (unit -> unit) 
        
  let s_of_filename = function
  | Normalized s -> s
  | Raw s -> s

  let filename_map f = function
  | Normalized s -> Normalized (f s)
  | Raw s -> Raw (f s)

  let (//) = sprintf "%s/%s"
  let concat f (B s) = filename_map (function "/" -> "" // s | filename -> filename // s) f
  let (///) = concat
  let init home = 
    { home ; home_ocamlversion = home // Globals.ocaml_version }

  let root = Raw "/"
  let cwd = Normalized (Run.normalize ".")

  let package _ s =
    (* REMARK this should be normalized *)
    Raw (Printf.sprintf "%s%s" (if s <> "" && s.[0] = '/' then "/" else "") (String.strip ~chars:"/" s))

  let lib t (Name n) = Raw (t.home_ocamlversion // "lib" // n)
  let bin t = Raw (t.home_ocamlversion // "bin")

  let mk_name_version t_home d ext n v = Raw (t_home // d // sprintf "%s%s" (Namespace.string_of_nv n v) ext)

  let mk_name_version_o t_home name ext = 
    function
    | None -> Raw (t_home // name)
    | Some (n, v) -> mk_name_version t_home name ext n v

  let index t = mk_name_version_o t.home "index" ".spec"

  let compil t c = Raw (t.home // "compilers" // c ^ ".compil")

  let archives_targz t = mk_name_version_o t.home "archives" ".tar.gz"

  let build t = mk_name_version_o t.home_ocamlversion "build" ""
  let installed t = Raw (t.home_ocamlversion // "installed")
  let config t = Raw (t.home // "config")

  let to_install t (n, v) = build t (Some (n, v)) /// B (Namespace.string_of_name n ^ ".install")

  let pconfig t (n, v) = build t (Some (n, v)) /// B (Namespace.string_of_name n ^ ".config")

  let keys t n = Raw (t.home // "keys" // Namespace.string_of_name n)
  let hashes t n = Raw (t.home // "hashes" // Namespace.string_of_name n)

  let contents f_dir f_fic f_notfound f =
    let fic = s_of_filename f in
    if Sys.file_exists fic then
      (if Sys.is_directory fic then f_dir else f_fic) fic
    else
      f_notfound fic

  let find_ f_fic = 
    contents
      (fun fic -> Directory (List.of_enum (Enum.map (fun s -> B s) (BatSys.files_of fic))))
      (fun fic -> File (f_fic fic))
      (fun fic -> Not_found fic)

  let find = find_ (fun fic -> Filename (Internal fic))

  let find_binary = find_ (fun fic -> Raw_binary (Run.read fic))

  let find_filename = find_ (fun fic -> Internal fic)

  let nv_of_extension version (B s) = 
    let s = 
      match BatString.right_chop s ".spec" with
        | Some s -> s
        | _ ->
          let rec aux s =
            match try Some (Filename.chop_extension s) with _ -> None with 
              | Some s -> aux s
              | _ -> s in
          aux s in

    match try Some (Namespace.nv_of_string s) with _ -> None with
    | Some nv -> nv
    | None -> Name s, Namespace.version_of_string version

  let file_exists f = Sys.file_exists (s_of_filename f)

  let is_directory f = 
    let s = s_of_filename f in
    if Sys.is_directory s then
      Some (Internal s)
    else
      None

  let check_suffix f suff =
    Filename.check_suffix (s_of_filename f) suff

  let index_list t =
    let index_path = index t None in
    let is_spec f =
      let file = concat index_path f in
      is_directory file = None 
      && check_suffix file ".spec" in
    let files =
      match find index_path with
      | Directory l -> List.filter is_spec l
      | File _
      | Not_found _ -> [] in
    List.map (nv_of_extension Namespace.default_version) files

  let remove f = 
    let rec aux fic = 
      log "remove %s" fic;
      if Sys.file_exists fic then
        match (Unix.lstat fic).Unix.st_kind with
        | Unix.S_DIR -> 
            let () = Enum.iter (fun f -> aux (fic // f)) (BatSys.files_of fic) in
            Unix.rmdir fic
        | Unix.S_REG
        | Unix.S_LNK -> Unix.unlink fic
        | _          -> failwith "to complete!" in
    aux (s_of_filename f)

  let add f content =
    log "add %s" (s_of_filename f);
    match content with
    | Directory d -> failwith "to complete !"
    | File (Binary (Raw_binary cts)) -> 
        let fic = s_of_filename  f in
        Run.mkdir
          (fun fic -> 
            begin
              Run.safe_unlink fic; 
              BatFile.with_file_out fic (fun oc -> BatString.print oc cts);
            end)
          fic
    | File (Filename (Internal fic)) ->
        begin match (Unix.lstat fic).Unix.st_kind with
        | Unix.S_DIR -> 
            Run.safe_rmdir fic;
            let rec aux f_from f_to = 
              (match (Unix.lstat f_from).Unix.st_kind with
              | Unix.S_DIR -> Enum.fold (fun b _ -> aux (f_from // b) (f_to // b)) () (BatSys.files_of f_from)
              | Unix.S_REG -> 
                  let () = 
                    if Sys.file_exists f_to then
                      Unix.unlink f_to
                    else
                      () in
                  Run.copy f_from f_to
              | _ -> failwith "to complete !") in
            aux fic (s_of_filename f)
        | Unix.S_REG ->
          Run.mkdir 
            (fun f_to -> 
              begin
                Run.safe_unlink f_to;
                Run.copy fic f_to;
              end)
            (s_of_filename f)
        | _ -> Printf.kprintf failwith "to complete ! copy the given filename %s" fic
        end

    | File (Filename(External _)) -> ()

    | Not_found s -> ()

  let exec t n_v = 
    Run.in_dir (s_of_filename (build t (Some n_v)))
      (Run.sys_commands_with_bin (s_of_filename (bin t)))

  let basename s = B (Filename.basename (s_of_filename s))

  let lstat s = Unix.lstat (s_of_filename s)
  let files_of f = BatSys.files_of (s_of_filename f)

  let dirname = filename_map Filename.dirname

  let add_rec f = 
    log "add_rec %s" (s_of_filename f);
    let () = (* check that [f] is not a file *)
      contents
        (fun _ -> ())
        (fun _ -> failwith "to complete !") 
        (fun _ -> ())
        f in

    let f_filename f f_basename = 
      List.map
        (fun fic ->
          if Sys.file_exists (s_of_filename fic) then begin
            f, 
            f_basename fic,
            match (lstat fic).Unix.st_kind with
            | Unix.S_DIR ->
                R_directory (Enum.map 
                               (fun f -> 
                                 let f = B f in
                                 f, R_filename [fic /// f])
                               (files_of fic))
            | Unix.S_REG -> R_file (Filename (Internal (s_of_filename fic)))
            | _ -> failwith "to complete !"
          end else
            Globals.error_and_exit "File %s does not exist." (s_of_filename fic))
    in

    let rec aux f (* <- filename dir *) name (* name of the value that will be destructed*) = function
    | R_directory l ->
        let f = f /// name in
        Enum.iter (fun (b, cts) -> aux f b cts) l
    | R_file cts -> add (f /// name) (File cts)
    | R_filename l -> 
        List.iter (fun (f, base_f, data) -> aux f base_f data) (f_filename f basename l)
    | R_lazy write_contents ->
        Run.mkdir (fun fic -> 
          Run.in_dir (Filename.dirname fic) write_contents ()
        ) (s_of_filename (f /// name)) in

    function
      | R_filename l -> 
        List.iter (fun (f, base_f, data) -> aux f base_f data) (f_filename f (basename) l)
      | R_lazy _ as r_lazy -> 
        let f, name = dirname f, basename f in
        aux f name r_lazy
      | _ -> failwith "to complete !"


  (* This function is called by the client after he receives a package
     archive from the server *)
  let extract nv = function
  | Archive (Raw_binary bin) -> 
      R_lazy (fun () ->
        (* As we received the binary from the server, it is "safe" to
           assume that the file will be untared at the right place
           (ie. in NAME-VERSION/) *)
        let oc = BatUnix.open_process_out "tar xzv" in
        BatIO.write_string oc bin;
        BatIO.close_out oc)
        
  | Links links ->
      R_lazy (fun () -> 
        if links.urls = [] && links.patches = [] then
          Globals.error_and_exit "The package contains no content";

        let rec download = function
        | [] -> ()
        | Internal f :: urls -> download_aux f urls
        | External (uri, url) :: urls ->
            match Run.download (uri, url) nv with
            | Run.Url_error   -> download urls
            | Run.From_http f -> download_aux f urls
            | Run.From_git    -> ()
        and download_aux f urls =
          if Run.untar f nv <> 0 then
            download urls in

        let patch p =
          match get_local_files p with
          | Some p ->
            let file = Printf.sprintf "%s/%s" (Namespace.to_string nv) p in
            if Sys.file_exists file then
              Globals.error_and_exit "%s already exits" file
            else
              add_rec (Raw (Namespace.to_string nv)) (R_filename [Raw p])
          | None -> 
            match p with
            | Internal p  ->
              if Run.patch p nv <> 0 then
                Globals.error_and_exit "Unable to apply path %S" p
            | External (uri, url) ->
              match Run.download (uri, url) nv with
              | Run.Url_error   -> Globals.error_and_exit "Patch %S is unavailable" url
              | Run.From_git    -> failwith "to complete"
              | Run.From_http p ->
                if Run.patch p nv <> 0 then
                  Globals.error_and_exit "Unable to apply path %S" p in
        
        download links.urls;
        List.iter patch links.patches;
      )

  let to_archive archive_filename tmp_nv = 
    let fic = s_of_filename tmp_nv in
    match
      Run.in_dir (Filename.dirname fic) 
        Sys.command (Printf.sprintf "tar czvf %s %s" archive_filename (Filename.basename fic))
    with
      | 0 -> ()
      | _ -> failwith "tar creation failed"

  let ocaml_options_of_library t name = 
    I (Printf.sprintf "%s" (s_of_filename (lib t name)))

  let string_of_filename = s_of_filename

  let file_not_found f =
    Globals.error_and_exit "%s not found" (string_of_filename f)

  let read f n = match f n with
  | None   -> file_not_found n
  | Some a -> a
end
