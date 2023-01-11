let num_padding_words = 15

let copy_as_padded (o : 'a) : 'a =
  let o = Obj.repr o in
  let n = Obj.new_block (Obj.tag o) (Obj.size o + num_padding_words) in
  for i = 0 to Obj.size o - 1 do
    Obj.set_field n i (Obj.field o i)
  done;
  Obj.magic n

let null _ = Obj.magic () [@@inline]

let make_padded_array n x =
  let a = Array.make (n + num_padding_words) (null ()) in
  if x != null () then Array.fill a 0 n x;
  a

let length_of_padded_array x = Array.length x - num_padding_words [@@inline]

let length_of_padded_array_minus_1 x = Array.length x - (num_padding_words + 1)
  [@@inline]
