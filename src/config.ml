open Mirage

let user =
  let doc = Key.Arg.info ~doc:"The default username." [ "user" ] in
  Key.(create "user" Arg.(opt string "mirage" doc))

let key =
  let doc =
    Key.Arg.info ~doc:"The pubkey for the default username." [ "key" ]
  in
  Key.(create "key" Arg.(opt string "xxx" doc))
(* the default key means that it is impossible to connect with this user *)

let port =
  let doc =
    Key.Arg.info ~doc:"The port number to listen for connections." [ "port" ]
  in
  Key.(create "port" Arg.(opt int 18022 doc))

let seed =
  let doc =
    Key.Arg.info ~doc:"The seed for the private/public key." [ "seed" ]
  in
  Key.(create "seed" Arg.(required string doc))

let main =
  foreign
    ~packages:
      [
        package ~min:"6.0.0" "cstruct";
        package ~min:"0.2.0" "awa-mirage";
        package "ethernet";
        package "io-page";
        package ~min:"6.0.1" "mirage-kv";
        package ~min:"6.0.0" "mirage-protocols";
        package ~min:"0.8.7" "fmt";
        package ~build:true "bos";
        package ~build:true "fpath";
      ]
    ~keys:[ Key.v port; Key.v user; Key.v key; Key.v seed ]
    "Unikernel.Main"
    (random @-> time @-> mclock @-> pclock @-> stackv4v6 @-> kv_rw @-> job)

let stack = generic_stackv4v6 default_network

(* *** *)

(* The following is using mirage-kv-mem as the disk layer, the data shared with sshfs won't
      resist to shutdown but this scenario can be convenient for a simple sharing method... *)

(* let my_fs = kv_rw_mem () *)

(* If you prefer to have a persistent storage layer you can use the following (chamelon as
      the filesystem, and ccm for encryption layer for your disk)

let aes_ccm_key =
  let doc =
    Key.Arg.info [ "aes-ccm-key" ]
      ~doc:"The key of the block device (hex formatted)"
  in
  Key.(create "aes-ccm-key" Arg.(required string doc))
*)
let program_block_size =
  let doc =
    Key.Arg.info [ "program_block_size" ]
      ~doc:
        "The program block size of the formatted fs layer (if using chamelon)"
  in
  Key.(create "program_block_size" Arg.(opt int 16 doc))

(* is_xen = Qubes target, is_solo5 = Spt or Hvt target, else = Unix target *)
let block =
  Key.(
    if_impl is_xen (block_of_file "private")
      (if_impl is_solo5 (block_of_file "storage")
         (block_of_file "disk.img")))

(*let encrypted_block = ccm_block aes_ccm_key block
let my_fs = chamelon ~program_block_size encrypted_block*)
let my_fs = chamelon ~program_block_size block


(* *** *)

let () =
  register "mirage_sshfs"
    [
      main
      $ default_random
      $ default_time
      $ default_monotonic_clock
      $ default_posix_clock
      $ stack
      $ my_fs;
    ]
