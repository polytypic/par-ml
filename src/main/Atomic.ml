include Stdlib.Atomic

[@@@ocaml.warning "-69"] (* Disable unused field warning. *)

type 'a atomic = {
  mutable value : 'a;
  s2 : int;
  s3 : int;
  s4 : int;
  s5 : int;
  s6 : int;
  s7 : int;
  s8 : int;
  s9 : int;
  sA : int;
  sB : int;
  sC : int;
  sD : int;
  sE : int;
  sF : int;
}

let make_fat value =
  Obj.magic
    {
      value;
      s2 = 0;
      s3 = 0;
      s4 = 0;
      s5 = 0;
      s6 = 0;
      s7 = 0;
      s8 = 0;
      s9 = 0;
      sA = 0;
      sB = 0;
      sC = 0;
      sD = 0;
      sE = 0;
      sF = 0;
    }

let fence atomic = fetch_and_add atomic 0 |> ignore [@@inline]
