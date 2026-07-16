/// Test collateral coin for the Assay MRK market (devnet demo; mintable via TreasuryCap).
module assay_markets::tmrk {
    use sui::coin::{Self, TreasuryCap};
    public struct TMRK has drop {}
    fun init(w: TMRK, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tMRK", b"Merck xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TMRK>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
