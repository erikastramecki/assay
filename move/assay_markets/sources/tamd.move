/// Test collateral coin for the Assay AMD market (devnet demo; mintable via TreasuryCap).
module assay_markets::tamd {
    use sui::coin::{Self, TreasuryCap};
    public struct TAMD has drop {}
    fun init(w: TAMD, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tAMD", b"AMD xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TAMD>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
