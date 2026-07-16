/// Test collateral coin for the Assay KO market (devnet demo; mintable via TreasuryCap).
module assay_markets::tko {
    use sui::coin::{Self, TreasuryCap};
    public struct TKO has drop {}
    fun init(w: TKO, ctx: &mut TxContext) {
        let (t, m) = coin::create_currency(w, 8, b"tKO", b"Coca-Cola xStock", b"Assay devnet test collateral", option::none(), ctx);
        transfer::public_freeze_object(m);
        transfer::public_transfer(t, ctx.sender());
    }
    public entry fun mint(cap: &mut TreasuryCap<TKO>, amount: u64, to: address, ctx: &mut TxContext) {
        coin::mint_and_transfer(cap, amount, to, ctx);
    }
}
