/// Test collateral coin for the Assay CVX market (devnet demo; mintable via TreasuryCap).
module assay_markets::tcvx {
    use sui::coin::{Self, TreasuryCap};
    public struct TCVX has drop {}
    fun init(w: TCVX, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tCVX", b"Chevron xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TCVX>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
