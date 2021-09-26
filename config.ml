open Mirage

let disk = "disk.img"

let user =
  let doc = Key.Arg.info ~doc:"The username to connect with." ["user"] in
  Key.(create "user" Arg.(opt string "mirage" doc))

let port =
  let doc = Key.Arg.info ~doc:"The port number to listen for connections." ["port"] in
  Key.(create "port" Arg.(opt int 18022 doc))

let img = block_of_file disk

let main =
  foreign
    ~packages:[
      package "cstruct";
      package "awa-lwt";
      package "mirage-crypto-rng.lwt";
      package "fat-filesystem";
      package "ethernet";
      package "io-page";
      package ~build:true "bos";
      package ~build:true "fpath";
    ]
    ~keys:[
      Key.abstract port;
      Key.abstract user;
    ]
    "Unikernel.Main" (network @-> time @-> block @-> job)

let () = register "mirage_sshfs" [ main $ default_network $ default_time $ img]