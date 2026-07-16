/// Test collateral coin for the Assay MRVL market (devnet demo; mintable via TreasuryCap).
module assay_markets::tmrvl {
    use sui::coin::{Self, TreasuryCap};
    public struct TMRVL has drop {}
    fun init(w: TMRVL, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tMRVL", b"Marvell xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TMRVL>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
