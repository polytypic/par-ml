let copy_as_padded (type t) (o : t) : t =
  let o = Obj.repr o in
  let n = Obj.new_block (Obj.tag o) (Obj.size o + 15) in
  for i = 0 to Obj.size o - 1 do
    Obj.set_field n i (Obj.field o i)
  done;
  Obj.magic n
