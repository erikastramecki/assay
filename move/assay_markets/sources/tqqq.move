/// Test collateral coin for the Assay QQQ market (devnet demo; mintable via TreasuryCap).
module assay_markets::tqqq {
    use sui::coin::{Self, TreasuryCap};
    public struct TQQQ has drop {}
    fun init(w: TQQQ, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tQQQ", b"Nasdaq 100 xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TQQQ>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
