(* mirage >= 4.9.0 & < 4.10.0 *)
open Mirage

let main =
  main
    ~packages:
      [
        package ~min:"6.0.0" "cstruct";
        package ~min:"0.5.1" "awa-mirage";
        package "ethernet";
        package "io-page";
        package ~min:"6.1.1" "mirage-kv";
        package ~min:"6.0.0" "mirage-protocols";
        package ~min:"0.8.7" "fmt";
        package ~build:true "bos";
        package ~build:true "fpath";
      ]
    "Unikernel.Main"
    (stackv4v6 @-> kv_rw @-> job)

let stack = generic_stackv4v6 default_network

(* *** *)

(* The following is using mirage-kv-mem as the disk layer, the data shared with sshfs won't
      resist to shutdown but this scenario can be convenient for a simple sharing method... *)

(* let my_fs = kv_rw_mem () *)

(* If you prefer to have a persistent storage layer you can use the following (chamelon as
      the filesystem, and ccm for encryption layer for your disk)
FIXME: outdated
let aes_ccm_key =
  let doc =
    Key.Arg.info [ "aes-ccm-key" ]
      ~doc:"The key of the block device (hex formatted)"
  in
  Key.(create "aes-ccm-key" Arg.(required string doc))
*)

let my_fs =
  let program_block_size =
    Runtime_arg.create ~pos:__POS__ "Unikernel.program_block_size"
  in
  (* is_xen = Qubes target, is_solo5 = Spt or Hvt target, else = Unix target *)
  let block =
    Key.(
      if_impl is_xen (block_of_file "private")
        (if_impl is_solo5 (block_of_file "storage")
           (block_of_file "disk.img")))
  in
  (*let encrypted_block = ccm_block aes_ccm_key block
  let my_fs = chamelon ~program_block_size encrypted_block*)
  chamelon ~program_block_size block

(* *** *)

let () =
  register "mirage_sshfs"
    [
      main
      $ stack
      $ my_fs
    ]
