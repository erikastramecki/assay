/// Test collateral coin for the Assay WMT market (devnet demo; mintable via TreasuryCap).
module assay_markets::twmt {
    use sui::coin::{Self, TreasuryCap};
    public struct TWMT has drop {}
    fun init(w: TWMT, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tWMT", b"Walmart xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TWMT>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
