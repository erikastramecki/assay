/// Test collateral coin for the Assay CRWD market (devnet demo; mintable via TreasuryCap).
module assay_markets::tcrwd {
    use sui::coin::{Self, TreasuryCap};
    public struct TCRWD has drop {}
    fun init(w: TCRWD, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tCRWD", b"CrowdStrike xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TCRWD>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
