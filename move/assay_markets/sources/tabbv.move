/// Test collateral coin for the Assay ABBV market (devnet demo; mintable via TreasuryCap).
module assay_markets::tabbv {
    use sui::coin::{Self, TreasuryCap};
    public struct TABBV has drop {}
    fun init(w: TABBV, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tABBV", b"AbbVie xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TABBV>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
