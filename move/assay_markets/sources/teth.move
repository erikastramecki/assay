/// Test collateral coin for the Assay ETH market (devnet demo; mintable via TreasuryCap).
module assay_markets::teth {
    use sui::coin::{Self, TreasuryCap};
    public struct TETH has drop {}
    fun init(w: TETH, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tETH", b"ETH", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TETH>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
