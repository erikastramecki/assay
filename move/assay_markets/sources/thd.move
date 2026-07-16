/// Test collateral coin for the Assay HD market (devnet demo; mintable via TreasuryCap).
module assay_markets::thd {
    use sui::coin::{Self, TreasuryCap};
    public struct THD has drop {}
    fun init(w: THD, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tHD", b"Home Depot xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<THD>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
