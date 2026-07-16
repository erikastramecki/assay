/// Test collateral coin for the Assay UNH market (devnet demo; mintable via TreasuryCap).
module assay_markets::tunh {
    use sui::coin::{Self, TreasuryCap};
    public struct TUNH has drop {}
    fun init(w: TUNH, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tUNH", b"UnitedHealth xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TUNH>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
