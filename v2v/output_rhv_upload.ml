(* virt-v2v
 * Copyright (C) 2009-2020 Red Hat Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 *)

open Printf
open Unix

open Std_utils
open Tools_utils
open Unix_utils
open Common_gettext.Gettext

open Types
open Utils

type rhv_options = {
  rhv_cafile : string option;
  rhv_cluster : string option;
  rhv_direct : bool;
  rhv_verifypeer : bool;
  rhv_disk_uuids : string list option;
}

let print_output_options () =
  printf (f_"Output options (-oo) which can be used with -o rhv-upload:

  -oo rhv-cafile=CA.PEM           Set ‘ca.pem’ certificate bundle filename.
  -oo rhv-cluster=CLUSTERNAME     Set RHV cluster name.
  -oo rhv-direct[=true|false]     Use direct transfer mode (default: false).
  -oo rhv-verifypeer[=true|false] Verify server identity (default: false).

You can override the UUIDs of the disks, instead of using autogenerated UUIDs
after their uploads (if you do, you must supply one for each disk):

  -oo rhv-disk-uuid=UUID          Disk UUID
")

let is_nonnil_uuid uuid =
  let nil_uuid = "00000000-0000-0000-0000-000000000000" in
  let rex_uuid = lazy (
    let hex = "[a-fA-F0-9]" in
    let str = sprintf "^%s{8}-%s{4}-%s{4}-%s{4}-%s{12}$" hex hex hex hex hex in
    PCRE.compile str
  ) in
  if uuid = nil_uuid then false
  else PCRE.matches (Lazy.force rex_uuid) uuid

let parse_output_options options =
  let rhv_cafile = ref None in
  let rhv_cluster = ref None in
  let rhv_direct = ref false in
  let rhv_verifypeer = ref false in
  let rhv_disk_uuids = ref None in

  List.iter (
    function
    | "rhv-cafile", v ->
       if !rhv_cafile <> None then
         error (f_"-o rhv-upload: -oo rhv-cafile set more than once");
       rhv_cafile := Some v
    | "rhv-cluster", v ->
       if !rhv_cluster <> None then
         error (f_"-o rhv-upload: -oo rhv-cluster set more than once");
       rhv_cluster := Some v
    | "rhv-direct", "" -> rhv_direct := true
    | "rhv-direct", v -> rhv_direct := bool_of_string v
    | "rhv-verifypeer", "" -> rhv_verifypeer := true
    | "rhv-verifypeer", v -> rhv_verifypeer := bool_of_string v
    | "rhv-disk-uuid", v ->
       if not (is_nonnil_uuid v) then
         error (f_"-o rhv-upload: invalid UUID for -oo rhv-disk-uuid");
       rhv_disk_uuids := Some (v :: (Option.default [] !rhv_disk_uuids))
    | k, _ ->
       error (f_"-o rhv-upload: unknown output option ‘-oo %s’") k
  ) options;

  let rhv_cafile = !rhv_cafile in
  let rhv_cluster = !rhv_cluster in
  let rhv_direct = !rhv_direct in
  let rhv_verifypeer = !rhv_verifypeer in
  let rhv_disk_uuids = Option.map List.rev !rhv_disk_uuids in

  { rhv_cafile; rhv_cluster; rhv_direct; rhv_verifypeer; rhv_disk_uuids }

(* We need nbdkit >= 1.22 for API_VERSION 2 and parallel threading model
 * in the python plugin.
 *)
let nbdkit_min_version = (1, 22, 0)
let nbdkit_min_version_string = "1.22.0"

let nbdkit_python_plugin = Config.nbdkit_python_plugin
let pidfile_timeout = 30
let finalization_timeout = 5*60

(* Check that the 'ovirtsdk4' Python module is available. *)
let error_unless_ovirtsdk4_module_available () =
  let res = run_command [ Python_script.python; "-c"; "import ovirtsdk4" ] in
  if res <> 0 then
    error (f_"the Python module ‘ovirtsdk4’ could not be loaded, is it installed?  See previous messages for problems.")

(* Check that nbdkit is available and new enough. *)
let error_unless_nbdkit_working () =
  if not (Nbdkit.is_installed ()) then
    error (f_"nbdkit is not installed or not working.  It is required to use ‘-o rhv-upload’.  See the virt-v2v-output-rhv(1) manual.")

let error_unless_nbdkit_min_version config =
  let version = Nbdkit.version config in
  if version < nbdkit_min_version then
    error (f_"nbdkit is not new enough, you need to upgrade to nbdkit ≥ %s")
      nbdkit_min_version_string

(* Check that the python3 plugin is installed and working
 * and can load the plugin script.
 *)
let error_unless_nbdkit_python_plugin_working plugin_script =
  let cmd = sprintf "nbdkit %s %s --dump-plugin >/dev/null"
              nbdkit_python_plugin
              (quote (Python_script.path plugin_script)) in
  debug "%s" cmd;
  if Sys.command cmd <> 0 then
    error (f_"nbdkit %s plugin is not installed or not working.  It is required if you want to use ‘-o rhv-upload’.

See also the virt-v2v-output-rhv(1) manual.")
      nbdkit_python_plugin

(* Check that nbdkit was compiled with SELinux support (for the
 * --selinux-label option).
 *)
let error_unless_nbdkit_compiled_with_selinux config =
  if have_selinux then (
    let selinux = try List.assoc "selinux" config with Not_found -> "no" in
    if selinux = "no" then
      error (f_"nbdkit was compiled without SELinux support.  You will have to recompile nbdkit with libselinux-devel installed, or else set SELinux to Permissive mode while doing the conversion.")
  )

(* Output sparse must be sparse.  We may be able to
 * lift this limitation in future, but it requires changes on the
 * RHV side.  See TODO file for details.  XXX
 *)
let error_current_limitation required_param =
  error (f_"rhv-upload: currently you must use ‘%s’.  This restriction will be loosened in a future version.") required_param

let error_unless_output_alloc_sparse output_alloc =
  if output_alloc <> Sparse then
    error_current_limitation "-oa sparse"

let json_optstring = function
  | Some s -> JSON.String s
  | None -> JSON.Null

class output_rhv_upload output_alloc output_conn
                        output_password output_storage
                        rhv_options =
  (* Create a temporary directory which will be deleted on exit. *)
  let tmpdir =
    let t = Mkdtemp.temp_dir "rhvupload." in
    rmdir_on_exit t;
    t in

  let diskid_file_of_id id = tmpdir // sprintf "diskid.%d" id in

  (* Create Python scripts for precheck, vmcheck, plugin and create VM. *)
  let precheck_script =
    Python_script.create ~name:"rhv-upload-precheck.py"
      Output_rhv_upload_precheck_source.code in
  let vmcheck_script =
    Python_script.create ~name:"rhv-upload-vmcheck.py"
      Output_rhv_upload_vmcheck_source.code in
  let plugin_script =
    Python_script.create ~name:"rhv-upload-plugin.py"
      Output_rhv_upload_plugin_source.code in
  let createvm_script =
    Python_script.create ~name:"rhv-upload-createvm.py"
      Output_rhv_upload_createvm_source.code in
  let deletedisks_script =
    Python_script.create ~name:"rhv-upload-deletedisks.py"
      Output_rhv_upload_deletedisks_source.code in

  (* JSON parameters which are invariant between disks. *)
  let json_params = [
    "verbose", JSON.Bool (verbose ());

    "output_conn", JSON.String output_conn;
    "output_password", JSON.String output_password;
    "output_storage", JSON.String output_storage;
    "output_sparse", JSON.Bool (match output_alloc with
                                | Sparse -> true
                                | Preallocated -> false);
    "rhv_cafile", json_optstring rhv_options.rhv_cafile;
    "rhv_cluster",
      JSON.String (Option.default "Default" rhv_options.rhv_cluster);
    "rhv_direct", JSON.Bool rhv_options.rhv_direct;

    (* The 'Insecure' flag seems to be a number with various possible
     * meanings, however we just set it to True/False.
     *
     * https://github.com/oVirt/ovirt-engine-sdk/blob/19aa7070b80e60a4cfd910448287aecf9083acbe/sdk/lib/ovirtsdk4/__init__.py#L395
     *)
    "insecure", JSON.Bool (not rhv_options.rhv_verifypeer);
  ] in

  (* nbdkit command line which is invariant between disks. *)
  let nbdkit_cmd = Nbdkit.new_cmd in
  let nbdkit_cmd = Nbdkit.set_exportname nbdkit_cmd "/" in
  let nbdkit_cmd = Nbdkit.set_verbose nbdkit_cmd (verbose ()) in
  let nbdkit_cmd = Nbdkit.set_plugin nbdkit_cmd nbdkit_python_plugin in
  let nbdkit_cmd = Nbdkit.add_arg nbdkit_cmd "script" (Python_script.path plugin_script) in

  (* Match number of parallel coroutines in qemu-img *)
  let nbdkit_cmd = Nbdkit.set_threads nbdkit_cmd 8 in

  let nbdkit_cmd =
    if have_selinux then
      (* Label the socket so qemu can open it. *)
      Nbdkit.set_selinux_label nbdkit_cmd
        (Some "system_u:object_r:svirt_socket_t:s0")
    else
      nbdkit_cmd in

  (* Delete disks.
   *
   * This ignores errors since the only time we are doing this is on
   * the failure path.
   *)
  let delete_disks uuids =
    let ids = List.map (fun uuid -> JSON.String uuid) uuids in
    let json_params =
      ("disk_uuids", JSON.List ids) :: json_params in
    ignore (Python_script.run_command deletedisks_script json_params [])
  in

object
  inherit output

  (* The storage domain UUID. *)
  val mutable rhv_storagedomain_uuid = None
  (* The cluster UUID. *)
  val mutable rhv_cluster_uuid = None
  (* The cluster CPU architecture *)
  val mutable rhv_cluster_cpu_architecture = None
  (* List of disk UUIDs. *)
  val mutable disks_uuids = []
  (* If we didn't finish successfully, delete on exit. *)
  val mutable delete_disks_on_exit = true

  method precheck () =
    Python_script.error_unless_python_interpreter_found ();
    error_unless_ovirtsdk4_module_available ();
    error_unless_nbdkit_working ();
    let config = Nbdkit.config () in
    error_unless_nbdkit_min_version config;
    error_unless_nbdkit_python_plugin_working plugin_script;
    error_unless_nbdkit_compiled_with_selinux config;
    error_unless_output_alloc_sparse output_alloc;

    (* Python code prechecks. *)
    let json_params = match rhv_options.rhv_disk_uuids with
    | None -> json_params
    | Some uuids ->
        let ids = List.map (fun uuid -> JSON.String uuid) uuids in
        ("rhv_disk_uuids", JSON.List ids) :: json_params
    in
    let precheck_fn = tmpdir // "v2vprecheck.json" in
    let fd = Unix.openfile precheck_fn [O_WRONLY; O_CREAT] 0o600 in
    if Python_script.run_command ~stdout_fd:fd
         precheck_script json_params [] <> 0 then
      error (f_"failed server prechecks, see earlier errors");
    let json = JSON_parser.json_parser_tree_parse_file precheck_fn in
    debug "precheck output parsed as: %s"
          (JSON.string_of_doc ~fmt:JSON.Indented ["", json]);
    rhv_storagedomain_uuid <-
       Some (JSON_parser.object_get_string "rhv_storagedomain_uuid" json);
    rhv_cluster_uuid <-
       Some (JSON_parser.object_get_string "rhv_cluster_uuid" json);
    rhv_cluster_cpu_architecture <-
       Some (JSON_parser.object_get_string "rhv_cluster_cpu_architecture" json)

  method as_options =
    "-o rhv-upload" ^
    (match output_alloc with
     | Sparse -> "" (* default, don't need to print it *)
     | Preallocated -> " -oa preallocated") ^
    sprintf " -oc %s -op %s -os %s"
            output_conn output_password output_storage

  method supported_firmware = [ TargetBIOS; TargetUEFI ]

  method transfer_format t = "raw"

  (* rhev-apt.exe will be installed (if available). *)
  method install_rhev_apt = true

  method write_out_of_order = true

  method prepare_targets source_name overlays guestcaps =
    let rhv_cluster_name =
      match List.assoc "rhv_cluster" json_params with
      | JSON.String s -> s
      | _ -> assert false in
    (match rhv_cluster_cpu_architecture with
    | None -> assert false
    | Some arch ->
      if arch <> guestcaps.gcaps_arch then
        error (f_"the cluster ‘%s’ does not support the architecture %s but %s")
          rhv_cluster_name guestcaps.gcaps_arch arch
    );

    let uuids =
      match rhv_options.rhv_disk_uuids with
      | None ->
        List.map (fun _ -> None) overlays
      | Some uuids ->
        if List.length uuids <> List.length overlays then
          error (f_"the number of ‘-oo rhv-disk-uuid’ parameters passed on the command line has to match the number of guest disk images (for this guest: %d)")
            (List.length overlays);
        List.map (fun uuid -> Some uuid) uuids in

    let output_name = source_name in
    let json_params =
      ("output_name", JSON.String output_name) :: json_params in

    (* Check that the VM does not exist.  This can't run in #precheck because
     * we need to know the name of the virtual machine.
     *)
    if Python_script.run_command vmcheck_script json_params [] <> 0 then
      error (f_"failed vmchecks, see earlier errors");

    (* Set up an at-exit handler so we delete the orphan disks on failure. *)
    at_exit (
      fun () ->
        if delete_disks_on_exit then (
          if disks_uuids <> [] then
            delete_disks disks_uuids
        )
    );

    (* Create an nbdkit instance for each disk and set the
     * target URI to point to the NBD socket.
     *)
    List.map (
      fun ((target_format, ov), uuid) ->
        let id = ov.ov_source.s_disk_id in
        let disk_name = sprintf "%s-%03d" output_name id in
        let json_params =
          ("disk_name", JSON.String disk_name) :: json_params in

        let disk_format =
          match target_format with
          | "raw" as fmt -> fmt
          | "qcow2" as fmt -> fmt
          | _ ->
             error (f_"rhv-upload: -of %s: Only output format ‘raw’ or ‘qcow2’ is supported.  If the input is in a different format then force one of these output formats by adding either ‘-of raw’ or ‘-of qcow2’ on the command line.")
                   target_format in
        let json_params =
          ("disk_format", JSON.String disk_format) :: json_params in

        let disk_size = ov.ov_virtual_size in
        let json_params =
          ("disk_size", JSON.Int disk_size) :: json_params in

        (* Ask the plugin to write the disk ID to a special file. *)
        let diskid_file = diskid_file_of_id id in
        let json_params =
          ("diskid_file", JSON.String diskid_file) :: json_params in

        let json_params =
          match uuid with
          | None -> json_params
          | Some uuid ->
            ("rhv_disk_uuid", JSON.String uuid) :: json_params in

        (* Write the JSON parameters to a file. *)
        let json_param_file = tmpdir // sprintf "params%d.json" id in
        with_open_out
          json_param_file
          (fun chan -> output_string chan (JSON.string_of_doc json_params));

        (* Add common arguments to per-target arguments. *)
        let cmd = Nbdkit.add_arg nbdkit_cmd "params" json_param_file in
        let sock, _ = Nbdkit.run_unix cmd in

        if have_selinux then (
          (* Note that Unix domain sockets have both a file label and
           * a socket/process label.  Using --selinux-label above
           * only set the socket label, but we must also set the file
           * label.
           *)
          ignore (
              run_command ["chcon"; "system_u:object_r:svirt_image_t:s0";
                           sock]
          );
        );

        (* Tell ‘qemu-img convert’ to write to the nbd socket which is
         * connected to nbdkit.
         *)
        let json_params = [
          "file.driver", JSON.String "nbd";
          "file.path", JSON.String sock;
          "file.export", JSON.String "/";
        ] in
        TargetURI ("json:" ^ JSON.string_of_doc json_params)
    ) (List.combine overlays uuids)

  method disk_copied t i nr_disks =
    (* Get the UUID of the disk image.  This file is written
     * out by the nbdkit plugin on successful finalization of the
     * transfer.
     *)
    let id = t.target_overlay.ov_source.s_disk_id in
    let diskid_file = diskid_file_of_id id in
    if not (wait_for_file diskid_file finalization_timeout) then
      error (f_"transfer of disk %d/%d failed, see earlier error messages")
            (i+1) nr_disks;
    let diskid = read_whole_file diskid_file in
    disks_uuids <- disks_uuids @ [diskid];

  method create_metadata source targets _ guestcaps inspect target_firmware =
    let image_uuids =
      match rhv_options.rhv_disk_uuids, disks_uuids with
      | None, [] ->
          error (f_"there must be ‘-oo rhv-disk-uuid’ parameters passed on the command line to specify the UUIDs of guest disk images (for this guest: %d)")
            (List.length targets)
      | Some uuids, _ -> uuids
      | None, uuids -> uuids in
    assert (List.length image_uuids = List.length targets);

    (* The storage domain UUID. *)
    let sd_uuid =
      match rhv_storagedomain_uuid with
      | None -> assert false
      | Some uuid -> uuid in

    (* The volume and VM UUIDs are made up. *)
    let vol_uuids = List.map (fun _ -> uuidgen ()) targets
    and vm_uuid = uuidgen () in

    (* Create the metadata. *)
    let ovf =
      Create_ovf.create_ovf source targets guestcaps inspect
                            target_firmware output_alloc
                            sd_uuid image_uuids vol_uuids vm_uuid
                            OVirt in
    let ovf = DOM.doc_to_string ovf in

    let json_params =
      match rhv_cluster_uuid with
      | None -> assert false
      | Some uuid -> ("rhv_cluster_uuid", JSON.String uuid) :: json_params in

    let ovf_file = tmpdir // "vm.ovf" in
    with_open_out ovf_file (fun chan -> output_string chan ovf);
    if Python_script.run_command createvm_script json_params [ovf_file] <> 0
    then
      error (f_"failed to create virtual machine, see earlier errors");

    (* Successful so don't delete on exit. *)
    delete_disks_on_exit <- false

end

let output_rhv_upload = new output_rhv_upload
let () = Modules_list.register_output_module "rhv-upload"
