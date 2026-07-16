/// Test collateral coin for the Assay MA market (devnet demo; mintable via TreasuryCap).
module assay_markets::tma {
    use sui::coin::{Self, TreasuryCap};
    public struct TMA has drop {}
    fun init(w: TMA, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tMA", b"Mastercard xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TMA>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
