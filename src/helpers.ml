let uint8_to_cs i =
  let cs = Cstruct.create 1 in
  Cstruct.set_uint8 cs 0 i;
  cs

let uint32_to_cs i =
  let cs = Cstruct.create 4 in
  Cstruct.BE.set_uint32 cs 0 i;
  cs

let uint32_of_cs cs = Cstruct.BE.get_uint32 cs 0

let uint64_to_cs i =
  let cs = Cstruct.create 8 in
  Cstruct.BE.set_uint64 cs 0 i;
  cs

let uint64_of_cs cs = Cstruct.BE.get_uint64 cs 0
