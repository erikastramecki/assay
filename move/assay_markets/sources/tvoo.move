/// Test collateral coin for the Assay VOO market (devnet demo; mintable via TreasuryCap).
module assay_markets::tvoo {
    use sui::coin::{Self, TreasuryCap};
    public struct TVOO has drop {}
    fun init(w: TVOO, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tVOO", b"Vanguard S&P xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TVOO>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
