module suijack::bcs {

  use std::bcs;
  use std::vector;

  /// Error codes
  const EInvalidVectorLength: u64 = 0;

  public fun serialize<MoveValue: drop>(v1: MoveValue, v2: MoveValue, v3: MoveValue): vector<u8> {
    let value = bcs::to_bytes(&v1);
    vector::append(&mut value, bcs::to_bytes(&v2));
    vector::append(&mut value, bcs::to_bytes(&v3));
    value
  }

  public fun deserialize(bytes: &vector<u8>): u256 {
    assert!(vector::length(bytes) >= 32, EInvalidVectorLength);
    let value: u256 = 0;
    let i: u64 = 0;
    while (i < 32) {
      value = value | ((*vector::borrow(bytes, i) as u256) << ((8 * (31 - i)) as u8));
      i = i + 1;
    };
    value
  }

  #[test_only]
  use std::hash::sha2_256;

  #[test]
  public fun test_bsc() {
    let v1 = 1234567890;
    let v2 = 655333224;
    let v3 = 1828781380470;
    let vv = serialize(v1, v2, v3);
    std::debug::print(&vv);
    let vs = sha2_256(vv);
    std::debug::print(&vs);
    let vd = deserialize(&vs);
    std::debug::print(&vd);
  }
}