/// Test collateral coin for the Assay COST market (devnet demo; mintable via TreasuryCap).
module assay_markets::tcost {
    use sui::coin::{Self, TreasuryCap};
    public struct TCOST has drop {}
    fun init(w: TCOST, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tCOST", b"Costco xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TCOST>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
