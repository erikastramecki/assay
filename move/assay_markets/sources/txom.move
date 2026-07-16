/// Test collateral coin for the Assay XOM market (devnet demo; mintable via TreasuryCap).
module assay_markets::txom {
    use sui::coin::{Self, TreasuryCap};
    public struct TXOM has drop {}
    fun init(w: TXOM, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tXOM", b"Exxon xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TXOM>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
