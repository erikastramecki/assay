/// Test collateral coin for the Assay AVGO market (devnet demo; mintable via TreasuryCap).
module assay_markets::tavgo {
    use sui::coin::{Self, TreasuryCap};
    public struct TAVGO has drop {}
    fun init(w: TAVGO, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tAVGO", b"Broadcom xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TAVGO>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
