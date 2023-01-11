val copy_as_padded : 'a -> 'a
(** Creates a shallow clone of the given object.  The clone will have 15 extra
    padding words added after the last used word.  When an array is padded the
    padding words change the length of the array. *)

val make_padded_array : int -> 'a -> 'a array
(** Creates a padded array.  The length of the array includes padding.  Use
    [length_of_padded_array] to get the unpadded length. *)

val length_of_padded_array : 'a array -> int
(** Returns the original length of a padded array. *)

val length_of_padded_array_minus_1 : 'a array -> int
(** Returns the original length of a padded array minus 1. *)
