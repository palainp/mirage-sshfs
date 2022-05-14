open Mirage

let user =
  let doc = Key.Arg.info ~doc:"The username to connect with." ["user"] in
  Key.(create "user" Arg.(opt string "mirage" doc))

let port =
  let doc = Key.Arg.info ~doc:"The port number to listen for connections." ["port"] in
  Key.(create "port" Arg.(opt int 18022 doc))

let seed =
  let doc = Key.Arg.info ~doc:"The seed for the private/public key." ["seed"] in
  Key.(create "seed" Arg.(required string doc))

let blockkey =
  let doc = Key.Arg.info ~doc:"The key for the reading/writing with the block device." ["blockkey"] in
  Key.(create "blockkey" Arg.(required string doc))

let main =
  foreign
    ~packages:[
      package ~min:"6.0.0" "cstruct";
      package ~min:"0.1.0" "awa-mirage";
      package "mirage-block-ccm";
      package ~sublibs:["kv"] ~min:"0.0.8" "chamelon";
      package "ethernet";
      package "io-page";
      package ~min:"6.0.0" "mirage-protocols";
      package ~min:"0.8.7" "fmt";
      package ~build:true "bos";
      package ~build:true "fpath";
    ]
    ~keys:[
      Key.v port;
      Key.v user;
      Key.v seed;
      Key.v blockkey;
    ]
    "Unikernel.Main" (random @-> time @-> mclock @-> pclock @-> stackv4v6 @-> block @-> job)

let stack = generic_stackv4v6 default_network
let img = Key.(if_impl is_solo5 (block_of_file "storage") (block_of_file "encrypted.img"))

let () = register "mirage_sshfs" [ main $ default_random $ default_time $ default_monotonic_clock $ default_posix_clock $ stack $ img]

