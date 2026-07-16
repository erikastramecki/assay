/// Test collateral coin for the Assay V market (devnet demo; mintable via TreasuryCap).
module assay_markets::tv {
    use sui::coin::{Self, TreasuryCap};
    public struct TV has drop {}
    fun init(w: TV, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tV", b"Visa xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TV>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
