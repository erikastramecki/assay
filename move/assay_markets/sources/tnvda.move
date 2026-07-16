/// Test collateral coin for the Assay NVDA market (devnet demo; mintable via TreasuryCap).
module assay_markets::tnvda {
    use sui::coin::{Self, TreasuryCap};
    public struct TNVDA has drop {}
    fun init(w: TNVDA, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tNVDA", b"NVIDIA xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TNVDA>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
