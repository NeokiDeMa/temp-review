module marketplace::collection_escrow_simple {
    use marketplace::{collection_escrow, marketplace::{Self as market_p, MarketPlace, OfferCap}};
    use sui::{balance::Balance, coin::{Self, Coin}, sui::SUI};

    // ====================== Errors ======================
    const EInsufficientAmount: u64 = 411;

    public struct CollectionOffer<phantom T: key + store> has key, store {
        id: UID,
        market_fee: u64,
        owner: address,
        balance: Balance<SUI>,
        offer_cap: ID,
    }

    public struct OfferKey<phantom T: key + store> has copy, drop, store {
        offer: ID,
    }

    #[allow(lint(self_transfer))]
    public fun offer<T: key + store>(
        market: &mut MarketPlace,
        payment: Coin<SUI>,
        ctx: &mut TxContext,
    ) {
        let balance = payment.into_balance();
        let value = balance.value();
        let market_fee =
            (((market.get_fee(ctx.sender()) as u128) * (value as u128)) / 10000) as u64;

        assert!(value >=  market_fee, EInsufficientAmount);
        let mut offer = CollectionOffer<T> {
            id: object::new(ctx),
            market_fee,
            owner: tx_context::sender(ctx),
            balance,
            offer_cap: object::id(market), // Temporary value
        };
        let offer_cap = market_p::create_offer_cap<T>(object::id(&offer), ctx);

        offer.offer_cap = object::id(&offer_cap);

        collection_escrow::emit_collection_offer_event<T>(
            object::id(market),
            object::id(&offer),
            object::id(&offer_cap),
            value,
            market_fee,
            ctx.sender(),
        );

        market.add_to_marketplace(OfferKey<T> { offer: object::id(&offer) }, offer);
        offer_cap.transfer_offer_cap(ctx);
    }

    #[allow(lint(self_transfer))]
    public fun accept_offer<T: key + store>(
        market: &mut MarketPlace,
        item: T,
        offer_id: ID,
        ctx: &mut TxContext,
    ) {
        let mut offer = market.remove_from_marketplace<OfferKey<T>, CollectionOffer<T>>(OfferKey<
            T,
        > {
            offer: offer_id,
        });
        let market_fee = offer.market_fee;
        let balance_value = offer.balance.value();

        let item_id = object::id(&item);

        let market_fee_coin = coin::take<SUI>(&mut offer.balance, market_fee, ctx);
        market.add_balance(market_fee_coin);

        let payment_coin = coin::take<SUI>(&mut offer.balance, balance_value, ctx);
        transfer::public_transfer(payment_coin, ctx.sender());
        transfer::public_transfer(item, offer.owner);

        let CollectionOffer<T> {
            id,
            market_fee: _,
            owner,
            balance,
            offer_cap,
        } = offer;

        market_p::create_receipt<T>(offer_cap, owner, ctx);

        let mut remain_coin = coin::zero<SUI>(ctx);
        remain_coin.balance_mut().join(balance);
        transfer::public_transfer(remain_coin, ctx.sender());
        object::delete(id);

        collection_escrow::emit_offer_accepted_event<T>(
            offer_id,
            item_id,
            ctx.sender(),
            owner,
            balance_value,
            offer_cap,
        );
    }

    #[allow(lint(self_transfer))]
    public fun revoke_offer<T: key + store>(
        market: &mut MarketPlace,
        offer_id: ID,
        offer_cap: OfferCap,
        ctx: &mut TxContext,
    ) {
        offer_cap.assert_offer_match(offer_id);

        let offer = market.remove_from_marketplace<OfferKey<T>, CollectionOffer<T>>(OfferKey<T> {
            offer: offer_id,
        });

        let offer_id = object::id(&offer);
        let CollectionOffer<T> {
            id,
            market_fee: _,
            owner: _,
            balance,
            offer_cap: _,
        } = offer;
        object::delete(id);
        offer_cap.delete_cap();

        let mut remain_coin = coin::zero<SUI>(ctx);
        remain_coin.balance_mut().join(balance);
        transfer::public_transfer(remain_coin, ctx.sender());

        collection_escrow::emit_offer_revoked_event<T>(
            offer_id,
            ctx.sender(),
        )
    }
}
