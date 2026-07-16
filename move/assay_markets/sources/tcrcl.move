/// Test collateral coin for the Assay CRCL market (devnet demo; mintable via TreasuryCap).
module assay_markets::tcrcl {
    use sui::coin::{Self, TreasuryCap};
    public struct TCRCL has drop {}
    fun init(w: TCRCL, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tCRCL", b"Circle xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TCRCL>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
