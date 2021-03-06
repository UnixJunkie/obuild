(*
 * gather dependencies in hashtable and DAGs
 * and create compilation state for one target
 *)
open Ext.Fugue
open Ext.Filepath
open Ext
open Analyze
open Types
open Helper
open Gconf
open Target
open Dependencies

type use_thread_flag = NoThread | WithThread
type ocaml_file_type = GeneratedModule | SimpleModule

module Module = struct
  exception DependsItself of Hier.t
  exception DependenciesProblem of Hier.t list
  exception DependencyNoOutput
  exception NotFound of (filepath list * Hier.t)

  type intf = {
    mtime : float;
    path : filepath
  }

  type file = {
    use_threads  : use_thread_flag;
    src_path    : filepath;
    src_mtime   : float;
    file_type   : ocaml_file_type;
    intf_desc   : intf option;
    use_pp      : Pp.t;
    oflags      : string list;
    dep_cwd_modules    : Hier.t list;
    dep_other_modules  : Modname.t list;
  }

  type dir = {
    path    : filepath;
    modules : Hier.t list
  }

  type t = DescFile of file | DescDir of dir

  let file_has_interface mdescfile =
    maybe false (fun _ -> true) mdescfile.intf_desc

  let has_interface = function
    | DescFile dfile -> file_has_interface dfile
    | DescDir _      -> false

  let make_dir path modules = DescDir { path; modules }
  let make_intf mtime path = { mtime; path }
  let make_file use_threads src_path src_mtime file_type intf_desc use_pp oflags dep_cwd_modules dep_other_modules =
    DescFile { use_threads; src_path; src_mtime; file_type; intf_desc; use_pp; oflags; dep_cwd_modules; dep_other_modules }
end

 (* live for the whole duration of a building process
 * which include compilations and linkings
*)
type build_state = { bstate_config : project_config }

type dir_spec = {
  src_dir      : filepath;
  dst_dir      : filepath;
  include_dirs : filepath list;
}

type compile_step = CompileModule    of Hier.t
                  | CompileInterface of Hier.t
                  | CompileDirectory of Hier.t
                  | CompileC         of filename
                  | LinkTarget       of target
                  | CheckTarget      of target

let string_of_compile_step cs = match cs with
  | CompileDirectory x -> "dir " ^ (Hier.to_string x)
  | CompileModule x    -> "mod " ^ (Hier.to_string x)
  | CompileInterface x -> "intf " ^ (Hier.to_string x)
  | CompileC x         -> "C " ^ (fn_to_string x)
  | LinkTarget x       -> "link " ^ (Target.get_target_name x)
  | CheckTarget x      -> "check " ^ (Target.get_target_name x)

(* represent a single compilation *)
type compilation_state = {
  compilation_modules  : (Hier.t, Module.t) Hashtbl.t;
  compilation_csources : filename list;
  compilation_dag      : compile_step Dag.t;
  compilation_pp       : Pp.t;
  compilation_filesdag : Filetype.id Dag.t;
  compilation_builddir_c  : filepath;
  compilation_builddir_ml : Types.ocaml_compilation_option -> filepath;
  compilation_include_paths : Types.ocaml_compilation_option -> Hier.t -> filepath list;
  compilation_linking_paths : filepath list;
  compilation_linking_paths_d : filepath list;
  compilation_linking_paths_p : filepath list;
  compilation_c_include_paths : filepath list;
  compilation_c_linking_paths : filepath list;
}

let init project = { bstate_config = project }

let get_compilation_order cstate =
  let filter_modules t : Hier.t option = match t with
    | (CompileC _) | (CompileInterface _) | (LinkTarget _) | (CheckTarget _) -> None
    | (CompileDirectory m) | (CompileModule m) -> if Hier.lvl m = 0 then Some m else None
  in
  list_filter_map filter_modules (Dagutils.linearize cstate.compilation_dag)

let camlp4Libname = Libname.of_string "camlp4"
let syntaxPredsCommon = [Meta.Predicate.Syntax;Meta.Predicate.Preprocessor]

let get_p4pred = function
  | Pp.Type.CamlP4O -> Meta.Predicate.Camlp4o
  | Pp.Type.CamlP4R -> Meta.Predicate.Camlp4r

let get_syntax_pp bstate preprocessor buildDeps =
  let conf = bstate.bstate_config in
  let p4pred = get_p4pred preprocessor in
  let stdlib = fp (get_ocaml_config_key "standard_library" conf) in
  list_filter_map (fun spkg ->
      if Analyze.is_pkg_internal conf spkg
      then (
        let lib = Project.find_lib bstate.bstate_config.project_file spkg in
        if lib.Project.lib_syntax
        then (
          (* TODO need to make sure that the bytecode option has been enabled for the syntax library *)
          let dir = Dist.get_build_exn (Dist.Target (Name.Lib lib.Project.lib_name)) in
          Some [fp_to_string (dir </> Libname.to_cmca ByteCode Normal lib.Project.lib_name) ]
        ) else None
      ) else (
        let meta = Analyze.get_pkg_meta spkg conf in
        let preds =
          if spkg = camlp4Libname
          then p4pred :: syntaxPredsCommon
          else syntaxPredsCommon
        in
        if Meta.Pkg.is_syntax meta spkg
        then (
          let includePath = Meta.getIncludeDir stdlib meta in
          Some ["-I"; fp_to_string includePath; Meta.Pkg.get_archive meta spkg preds]
        ) else
          None
      )
    ) buildDeps

(* get every module description
 * and their relationship with each other
*)
let get_modules_desc bstate target toplevelModules =
  let autogenDir = Dist.get_build_exn Dist.Autogen in
  let modulesDeps = Hashtbl.create 64 in
  let file_search_paths hier = [target.target_obits.target_srcdir <//> Hier.to_dirpath hier; autogenDir] in

  let targetPP = (match target.target_obits.target_pp with
      | None    -> Pp.none
      | Some pp ->
        let conf = bstate.bstate_config in
        let nodes = List.rev (Taskdep.linearize bstate.bstate_config.project_pkgdeps_dag Taskdep.FromParent
                                [Analyze.Target target.target_name]) in
        let syntaxPkgs = list_filter_map (fun (node) ->
            match node with
            | Dependency dep -> Some dep
            | _              -> None
          ) nodes
        in
        verbose Verbose " all packages : [%s]\n%!" (Utils.showList "," Libname.to_string syntaxPkgs);
        let p4pred = get_p4pred pp in
        let p4Meta = Analyze.get_pkg_meta camlp4Libname conf in
        let preproc = (snd p4Meta).Meta.Pkg.preprocessor in
        let archive = [Meta.Pkg.get_archive p4Meta camlp4Libname (p4pred::syntaxPredsCommon)] in

        (*verbose Verbose " camlp4 strs: [%s]\n%!" (Utils.showList "] [" id camlp4Strs);*)
        let camlp4Strs = get_syntax_pp bstate pp syntaxPkgs in
        Pp.some preproc (archive :: camlp4Strs)
    ) in

  let module_lookup_method = Hier.to_filename::Hier.to_generators @ [Hier.to_directory; Hier.to_interface] in
  let get_one hier =
    let moduleName = Hier.to_string hier in
    verbose Verbose "Analysing %s\n%!" moduleName;
    let srcPath =
      try Utils.find_choice_in_paths (file_search_paths hier) (List.map (fun f -> f hier) module_lookup_method)
      with Utils.FilesNotFoundInPaths (paths, _) -> raise (Module.NotFound (paths, hier))
    in
    let srcDir = srcPath </> Modname.to_directory (Hier.leaf hier) in

    let module_desc_ty =
      if Filesystem.is_dir srcDir
      then (
        let modules = Filesystem.list_dir_pred_map (fun f ->
            let fp = srcDir </> f in
            if Filesystem.is_dir fp
            then
              (* Should avoid directory such as .git/.svn etc. *)
              if not (Modname.string_all Modname.char_is_valid_modchar (fn_to_string f)) then
                None
              else
                Some (Modname.of_directory f)
            else (match Filetype.of_filepath fp with
                | Filetype.FileML  -> Some (Modname.of_filename f)
                | Filetype.FileOther s -> if Generators.is_generator_ext s then Some (Modname.of_filename f)
                  else None
                | _                -> None
              )
          ) srcDir
        in
        Module.make_dir currentDir (List.map (fun m -> Hier.append hier m) modules)
      ) else (
        let generators_files = List.map (fun gen_fun -> gen_fun hier srcPath) Hier.to_generators in
        let generator_file = try
            Some (List.find (fun file -> Filesystem.exists file) generators_files)
          with Not_found -> None in
        let srcPath =
          match generator_file with
          | None -> srcPath
          | Some f ->
            verbose Debug "  %s is a generator\n%!" moduleName;
            let actual_src_path = Dist.get_build_exn (Dist.Target target.target_name) in
            let dest_file = Hier.to_filename hier actual_src_path in
            if not (Filesystem.exists dest_file) ||
               ((Filesystem.getModificationTime dest_file) < (Filesystem.getModificationTime f)) then begin
              let w = Generators.run (actual_src_path </> Modname.to_directory (Hier.leaf hier)) f in
              print_warnings w
            end;
            actual_src_path
        in
        let srcFile = Hier.to_filename hier srcPath in
        let intfFile = Hier.to_interface hier srcPath in
        let modTime = Filesystem.getModificationTime srcFile in
        let hasInterface = Filesystem.exists intfFile in
        let intfModTime = Filesystem.getModificationTime intfFile in

        (* augment pp if needed with per-file dependencies *)
        let pp = match target.target_obits.target_pp with
          | None              -> Pp.none
          | Some preprocessor ->
            (* FIXME: we should re-use the dependency DAG here, otherwise we might end up in the case
             * where the extra dependencies are depending not in the correct order
            *)
            let extraDeps = List.concat (List.map (fun x -> x.target_extra_builddeps) (find_extra_matching target (Hier.to_string hier))) in
            Pp.append targetPP (get_syntax_pp bstate preprocessor (List.map fst extraDeps))
        in

        verbose Debug "  %s has mtime %f\n%!" moduleName modTime;
        if hasInterface then
          verbose Debug "  %s has interface (mtime=%f)\n%!" moduleName intfModTime;

        let dopt = {
          dep_includes = file_search_paths hier;
          dep_pp       = pp
        } in
        let allDeps = match runOcamldep dopt srcFile with
          | []   -> raise Module.DependencyNoOutput
          | ml::mli::_ -> list_uniq (ml @ mli)
          | x::_ -> x
        in
        verbose Debug "  %s depends on %s\n%!" moduleName (String.concat "," allDeps);
        let (cwdDepsInDir, otherDeps) = List.partition (fun dep ->
            try
              let _ = Utils.find_choice_in_paths (file_search_paths hier)
                  (List.map (fun x -> x (Hier.of_modname dep)) module_lookup_method)
              in true
            with
              Utils.FilesNotFoundInPaths _ -> false
          ) allDeps in
        verbose Debug "  %s internally depends on %s\n%!" moduleName (String.concat "," (List.map Modname.to_string cwdDepsInDir));
        let use_thread =
          if List.mem (Modname.wrap "Thread") otherDeps
          || List.mem (Modname.wrap "Condition") otherDeps
          || List.mem (Modname.wrap "Mutex") otherDeps
          then WithThread
          else NoThread
        in
        let cwdDeps = List.map (fun x -> maybe (Hier.make [x]) (fun z -> Hier.append z x) (Hier.parent hier)) cwdDepsInDir in
        (if List.mem hier cwdDeps then
           raise (Module.DependsItself hier)
        );
        let intfDesc =
          if hasInterface
          then Some (Module.make_intf intfModTime intfFile)
          else None
        in 
        Module.make_file use_thread srcFile modTime 
          (if generator_file = None then SimpleModule else GeneratedModule)
          intfDesc pp
          (target.target_obits.target_oflags @ 
           (List.concat (List.map (fun x -> x.target_extra_oflags) (find_extra_matching target (Hier.to_string hier)))))
          cwdDeps otherDeps
      )
    in
    module_desc_ty

  in
  let rec loop modname =
    if Hashtbl.mem modulesDeps modname
    then ()
    else (
      let mdesc = get_one modname in
      Hashtbl.add modulesDeps modname mdesc;
      (* TODO: don't query single modules at time, where ocamldep supports M modules.
         tricky with single file syntax's pragma. *)
      match mdesc with
      | Module.DescFile dfile -> List.iter loop dfile.Module.dep_cwd_modules
      | Module.DescDir  ddir  -> List.iter loop ddir.Module.modules
    )
  in
  List.iter (fun m -> loop m) toplevelModules;
  modulesDeps

(* prepare modules dependencies and various compilation state
 * that is going to be required for compilation and linking.
*)
let prepare_target_ bstate buildDir target toplevelModules =
  let autogenDir = Dist.get_build_exn Dist.Autogen in
  let buildDirP = buildDir </> fn "opt-p" in
  let buildDirD = buildDir </> fn "opt-d" in

  let cbits = target.target_cbits in
  let obits = target.target_obits in

  verbose Verbose "preparing compilation for %s\n%!" (Target.get_target_name target);

  let modulesDeps = get_modules_desc bstate target toplevelModules in

  (* create 2 dags per target
   * - stepsDag is a DAG of all the tasks to achieve the target (compilation only, not linking yet)
   * - filesDag is a DAG of all the files dependencies (C files & H files)
   **)
  let get_dags () =
    let filesDag = Dag.init () in
    let stepsDag = Dag.init () in
    let h = hashtbl_map (fun dep -> match dep with
        | Module.DescDir _      -> []
        | Module.DescFile dfile -> dfile.Module.dep_cwd_modules
      ) modulesDeps
    in
    while Hashtbl.length h > 0 do
      let freeModules = Hashtbl.fold (fun k v acc -> if v = [] then k :: acc else acc) h [] in
      if freeModules = []
      then raise (Module.DependenciesProblem (hashtbl_keys h))
      else ();
      List.iter (fun m ->
          let mdep = Hashtbl.find modulesDeps m in
          let mStep = match mdep with
            | Module.DescFile f ->
              (* if it is a .mli only module ... *)
              if not ((Filesystem.exists f.Module.src_path)) && (f.Module.file_type = SimpleModule) then
                CompileInterface m
              else begin
                if Module.has_interface mdep then (
                  Dag.addEdge (CompileModule m) (CompileInterface m) stepsDag;
                );
                CompileModule m
              end
            | Module.DescDir descdir ->
              let mStep = CompileDirectory m in
              List.iter (fun dirChild ->
                  (*printf "  %s depends %s" (string_of_compilation_step mStep) ((Compi *)
                  let depChild = Hashtbl.find modulesDeps dirChild in
                  let cStep = match depChild with
                    | Module.DescFile _ -> CompileModule dirChild
                    | Module.DescDir _ -> CompileDirectory dirChild
                  in
                  Dag.addEdge mStep cStep stepsDag
                ) descdir.Module.modules;
              mStep
          in
          Dag.addNode mStep stepsDag;

          Hashtbl.iter (fun k v ->
              if k <> m then (
                if List.mem m v then (
                  let kdep = Hashtbl.find modulesDeps k in
                  match kdep with
                  | Module.DescFile kFile ->
                    if Module.has_interface kdep
                    then (
                      Dag.addEdgesConnected [CompileModule k; CompileInterface k; mStep] stepsDag
                    ) else
                      Dag.addEdge (CompileModule k) mStep stepsDag
                  | Module.DescDir kDir ->
                    Dag.addEdge (CompileDirectory k) mStep stepsDag
                )
              )
            ) h;
        ) freeModules;
      let roots = Dag.getRoots stepsDag in
      List.iter (fun r ->
          match r with
          | CompileModule _ | CompileDirectory _->
            Dag.addEdge (LinkTarget target) r stepsDag;
            Dag.addEdge (CheckTarget target) (LinkTarget target) stepsDag;
          | _ -> ()
        )
        roots;

      hashtbl_modify_all (fun v -> List.filter (fun x -> not (List.mem x freeModules)) v) h;
      List.iter (Hashtbl.remove h) freeModules;
    done;

    (* just append each C sources as single node in the stepsDag *)
    if cbits.target_csources <> [] then (
      let objDeps = runCCdep cbits.target_cdir cbits.target_csources in

      List.iter (fun cSource ->
          let (fps : filepath list) =
            try List.assoc (Filetype.replace_extension cSource Filetype.FileO) objDeps
            with _ -> failwith ("cannot find dependencies for " ^ fn_to_string cSource)
          in
          let cFile = cbits.target_cdir </> cSource in
          let hFiles = List.map (fun x -> Filetype.make_id (Filetype.FileH, x))
              (List.filter (fun x -> Filetype.of_filepath x = Filetype.FileH) fps)
          in
          let oFile = buildDir </> (cSource <.> "o") in
          let cNode = Filetype.make_id (Filetype.FileC, cFile) in
          let oNode = Filetype.make_id (Filetype.FileO, oFile) in

          (* add C source information into the files DAG *)
          Dag.addEdge oNode cNode filesDag;
          Dag.addChildrenEdges oNode hFiles filesDag;

          (* add C source compilation task into the step DAG *)
          Dag.addNode (CompileC cSource) stepsDag
        ) cbits.target_csources;
    );

    (stepsDag, filesDag)
  in
  let (dag, fdag) = get_dags () in

  if gconf.dump_dot
  then (
    let dotDir = Dist.create_build Dist.Dot in
    let path = dotDir </> fn (Target.get_target_name target ^ ".dot") in
    let reducedDag = Dag.transitive_reduction dag in
    let dotContent = Dag.toDot string_of_compile_step (Target.get_target_name target) true reducedDag in
    Filesystem.writeFile path dotContent;

    let path = dotDir </> fn (Target.get_target_name target ^ ".files.dot") in
    let dotContent = Dag.toDot (fun fdep -> Filetype.to_string (Filetype.get_type fdep) ^ " " ^ 
                                            fp_to_string (Filetype.get_path fdep))
        (Target.get_target_name target) true fdag in
    Filesystem.writeFile path dotContent;

  );

  let conf = bstate.bstate_config in
  let stdlib = fp (get_ocaml_config_key "standard_library" conf) in

  let depPkgs = Analyze.get_pkg_deps target conf in
  let (depsInternal,depsSystem) = List.partition (fun dep ->
      match Hashtbl.find conf.project_dep_data dep with
      | Internal -> true
      | _ -> false) depPkgs in
  let depIncPathInter = List.map (fun dep ->
      Dist.get_build_exn (Dist.Target (Name.Lib dep))) depsInternal in
  let depIncPathSystem = List.map (fun dep ->
      Meta.getIncludeDir stdlib (Hashtbl.find conf.project_pkg_meta dep.Libname.main_name)) depsSystem in
  let depIncludePaths = depIncPathInter @ depIncPathSystem in
  let depIncludePathsD = List.map (fun fp -> fp </> fn "opt-d") depIncPathInter @ depIncPathSystem in
  let depIncludePathsP = List.map (fun fp -> fp </> fn "opt-p") depIncPathInter @ depIncPathSystem in
  let depLinkingPaths =
    List.map (fun dep ->
        match Hashtbl.find conf.project_dep_data dep with
        | Internal -> Dist.get_build_exn (Dist.Target (Name.Lib dep))
        | System   -> Meta.getIncludeDir stdlib (Hashtbl.find conf.project_pkg_meta dep.Libname.main_name)
      ) depPkgs
  in
  let cdepsIncludePaths : filepath list =
    cbits.target_clibpaths
    @ List.concat (List.map (fun (cpkg,_) -> (Hashtbl.find bstate.bstate_config.project_cpkgs cpkg).cpkg_conf_includes) cbits.target_cpkgs)
  in
  let cCamlIncludePath = fp (Analyze.get_ocaml_config_key "standard_library" bstate.bstate_config) in

  { compilation_modules  = modulesDeps
  ; compilation_csources = cbits.target_csources
  ; compilation_dag      = dag
  ; compilation_pp       = Pp.none
  ; compilation_filesdag = fdag
  ; compilation_builddir_c  = buildDir
  ; compilation_builddir_ml = (fun m ->
      match m with
      | Normal    -> buildDir
      | WithDebug -> buildDirD
      | WithProf  -> buildDirP)
  ; compilation_include_paths = (fun m hier ->
      ((match m with
          | Normal    -> buildDir
          | WithDebug -> buildDirD
          | WithProf  -> buildDirP) <//> Hier.to_dirpath hier) :: [autogenDir; obits.target_srcdir <//> Hier.to_dirpath hier ] @
      (match m with
       | Normal    -> depIncludePaths
       | WithDebug -> depIncludePathsD
       | WithProf  -> depIncludePathsP))
  ; compilation_linking_paths = [buildDir] @ depLinkingPaths
  ; compilation_linking_paths_p = [buildDirP;buildDir] @ depLinkingPaths
  ; compilation_linking_paths_d = [buildDirD;buildDir] @ depLinkingPaths
  ; compilation_c_include_paths = [cbits.target_cdir] @ cdepsIncludePaths @ [cCamlIncludePath; autogenDir]
  ; compilation_c_linking_paths = [buildDir]
  }

let prepare_target bstate buildDir target toplevelModules =
  try prepare_target_ bstate buildDir target toplevelModules
  with exn ->
    verbose Verbose "Prepare.target : uncaught exception %s\n%!" (Printexc.to_string exn);
    raise exn
