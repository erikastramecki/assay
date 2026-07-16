/// Test collateral coin for the Assay HOOD market (devnet demo; mintable via TreasuryCap).
module assay_markets::thood {
    use sui::coin::{Self, TreasuryCap};
    public struct THOOD has drop {}
    fun init(w: THOOD, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tHOOD", b"Robinhood xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<THOOD>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
