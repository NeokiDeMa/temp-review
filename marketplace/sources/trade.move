// SPDX-License-Identifier: MIT
module marketplace::trade {
    use kiosk::{floor_price_rule as floor_rule, kiosk_lock_rule as l_rule, royalty_rule as r_rule};
    use marketplace::{marketplace::{add_balance, MarketPlace, get_fee}, utils};
    use std::string::String;
    use sui::{
        coin::{Self, Coin},
        event::emit,
        kiosk::{Self, Kiosk, PurchaseCap, KioskOwnerCap},
        sui::SUI,
        transfer_policy::{TransferRequest, TransferPolicy}
    };

    public struct SItemWithPurchaseCap<phantom T: key + store> has key {
        id: UID,
        // Kiosk id
        kioskId: ID,
        // purchaseCap for the item
        purchaseCap: PurchaseCap<T>,
        // Id of the item that is listed
        item_id: ID,
        // Minimum price for the item
        min_price: u64,
        // Owner of the kiosk
        owner: address,
        // Royalty fee for the item
        royalty_fee: u64,
        // MarketPlace Fee,
        marketplace_fee: u64,
    }

    // ======================== Error  =======================
    const ENotAuthorized: u64 = 400;
    const ENotSameKiosk: u64 = 401;
    const ENotSameItem: u64 = 402;
    const ENotEnoughFunds: u64 = 403;

    // ======================== Events ========================

    public struct ItemListedEvent has copy, drop {
        kiosk: ID,
        kiosk_cap: ID,
        shared_purchaseCap: ID,
        item: ID,
        item_type: String,
        price: u64,
        marketplace_fee: u64,
        royalty_fee: u64,
        owner: address,
    }

    public struct ItemUpdatedEvent has copy, drop {
        kiosk: ID,
        kiosk_cap: ID,
        item: ID,
        item_type: String,
        shared_purchaseCap: ID,
        price: u64,
        marketplace_fee: u64,
        royalty_fee: u64,
        owner: address,
    }

    public struct ItemDelistedEvent has copy, drop {
        kiosk: ID,
        item: ID,
        item_type: String,
        shared_purchaseCap: ID,
        owner: address,
    }

    public struct ItemBoughtEvent has copy, drop {
        kiosk: ID,
        item: ID,
        item_type: String,
        price: u64,
        shared_purchaseCap: ID,
        buyer: address,
    }

    // ==================== User Functions  ========================

    /// @dev This function lists an item in a kiosk on the marketplace with purchase cap,
    ///      and stores price and fee information in the shared purchase cap.
    /// @notice This function lists an item placed in a kiosk.
    /// @param market The reference to the marketplace where the item is to be listed.
    /// @param kiosk_cap A capability object that allows modification of the kiosk.
    /// @param kiosk A mutable reference to the kiosk from which the item is listed.
    /// @param tp The transfer policy associated with the listed item.
    /// @param item_id The ID of the item to be listed in the kiosk.
    /// @param price The price of the item being listed (in mist unit).
    /// @param ctx The transaction context of the sender.
    public fun list_kiosk_item<T: key + store>(
        market: &MarketPlace,
        kiosk_cap: &KioskOwnerCap,
        kiosk: &mut Kiosk,
        tp: &TransferPolicy<T>,
        item_id: ID,
        price: u64,
        ctx: &mut TxContext,
    ) {
        let kioskId = object::id(kiosk);
        // List with purchase cap checks if kiosk cap has access
        let purchase_cap = kiosk::list_with_purchase_cap<T>(kiosk, kiosk_cap, item_id, price, ctx);

        let mut royalty_fee = 0;
        if (tp.has_rule<T, r_rule::Rule>()) {
            royalty_fee = r_rule::fee_amount(tp, price);
        };

        let marketplace_fee =
            (((get_fee(market, tx_context::sender(ctx)) as u128) * (price as u128)) / 10000) as u64;

        let new_UID = object::new(ctx);
        let new_id = object::uid_to_inner(&new_UID);
        transfer::share_object(SItemWithPurchaseCap<T> {
            id: new_UID,
            kioskId: kioskId,
            purchaseCap: purchase_cap,
            item_id,
            min_price: price,
            owner: tx_context::sender(ctx),
            royalty_fee,
            marketplace_fee: marketplace_fee,
        });
        // add the royalty fee and the marketplace fee to the price to the DB
        let price = price + royalty_fee + marketplace_fee;
        emit(ItemListedEvent {
            kiosk: kioskId,
            kiosk_cap: object::id(kiosk_cap),
            shared_purchaseCap: new_id,
            item: item_id,
            item_type: utils::type_to_string<T>(),
            price: price,
            marketplace_fee,
            royalty_fee,
            owner: tx_context::sender(ctx),
        });
    }

    /// @dev This function lists an item in a kiosk on the marketplace with purchase cap,
    ///      and stores price and fee information in the shared purchase cap.
    /// @notice This function places and lists an item into a kiosk.
    /// @param market The reference to the marketplace where the item is to be listed.
    /// @param kiosk_cap A capability object that allows modification of the kiosk.
    /// @param kiosk A mutable reference to the kiosk from which the item is listed.
    /// @param tp The transfer policy associated with the listed item.
    /// @param item The item to be listed in the kiosk.
    /// @param price The price of the item being listed (in mist unit).
    /// @param ctx The transaction context of the sender.
    public fun list<T: key + store>(
        market: &MarketPlace,
        kiosk_cap: &KioskOwnerCap,
        kiosk: &mut Kiosk,
        tp: &TransferPolicy<T>,
        item: T,
        price: u64, // 200 SUI
        ctx: &mut TxContext,
    ) {
        let item_id = object::id(&item);
        let kiosk_id = object::id(kiosk);

        kiosk::place<T>(kiosk, kiosk_cap, item);
        let purchase_cap = kiosk::list_with_purchase_cap<T>(kiosk, kiosk_cap, item_id, price, ctx);

        let mut royalty_fee = 0;
        if (tp.has_rule<T, r_rule::Rule>()) {
            royalty_fee = r_rule::fee_amount(tp, price);
        };

        let marketplace_fee =
            (((get_fee(market, tx_context::sender(ctx)) as u128) * (price as u128)) / 10000) as u64;

        let new_UID = object::new(ctx);
        let new_id = object::uid_to_inner(&new_UID);
        transfer::share_object(SItemWithPurchaseCap<T> {
            id: new_UID,
            kioskId: kiosk_id,
            purchaseCap: purchase_cap,
            item_id,
            min_price: price,
            owner: tx_context::sender(ctx),
            royalty_fee,
            marketplace_fee,
        });
        // add the royalty fee and the marketplace fee to the price to the DB
        let price = price + royalty_fee + marketplace_fee;
        emit(ItemListedEvent {
            kiosk: kiosk_id,
            kiosk_cap: object::id(kiosk_cap),
            shared_purchaseCap: new_id,
            item: item_id,
            item_type: utils::type_to_string<T>(),
            price: price,
            marketplace_fee,
            royalty_fee,
            owner: tx_context::sender(ctx),
        });
    }

    /// @dev This function updates an existing kiosk listing by modifying its price and recalculating its fees.
    /// @param market The reference to the marketplace where the item is listed.
    /// @param s_item_pc A mutable reference to the `SItemWithPurchaseCap` representing the listed item to be updated.
    /// @param kiosk_cap A capability object that allows modification of the kiosk.
    /// @param kiosk A mutable reference to the kiosk from which the item is listed.
    /// @param tp The transfer policy associated with the listed item.
    /// @param item The ID of the item listed in the kiosk.
    /// @param price The price of the item listed (in mist unit).
    /// @param ctx The transaction context of the sender.
    public fun update_listing<T: key + store>(
        market: &MarketPlace,
        s_item_pc: &mut SItemWithPurchaseCap<T>,
        kiosk_cap: &KioskOwnerCap,
        kiosk: &mut Kiosk,
        tp: &TransferPolicy<T>,
        item: ID,
        price: u64,
        ctx: &mut TxContext,
    ) {
        kiosk.has_access(kiosk_cap);

        let caller = ctx.sender();
        let owner = s_item_pc.owner;
        let item_id = s_item_pc.item_id;
        let kioskId = s_item_pc.kioskId;

        assert!(caller == owner, ENotAuthorized);
        assert!(item_id == item, ENotSameItem);
        assert!(kioskId == object::id(kiosk), ENotSameKiosk);

        if (tp.has_rule<T, r_rule::Rule>()) {
            s_item_pc.royalty_fee = r_rule::fee_amount(tp, price);
        };

        s_item_pc.marketplace_fee =
            (((get_fee(market, tx_context::sender(ctx)) as u128) * (price as u128)) / 10000) as u64;

        s_item_pc.min_price = price;

        emit(ItemUpdatedEvent {
            kiosk: kioskId,
            kiosk_cap: object::id(kiosk_cap),
            item: item,
            item_type: utils::type_to_string<T>(),
            shared_purchaseCap: object::uid_to_inner(&s_item_pc.id),
            price: price,
            marketplace_fee: s_item_pc.marketplace_fee,
            royalty_fee: s_item_pc.royalty_fee,
            owner: caller,
        });
    }

    /// @dev This function delists an item from a kiosk, ensuring all required permissions and checks
    ///      are passed before performing the delisting action. The purchase cap is returned and the item is no longer
    ///      available for purchase through the kiosk.
    /// @param s_item_pc A struct containing the item details, purchase cap, and ownership information.
    /// @param kiosk_cap A capability object that allows modification of the kiosk.
    /// @param kiosk A mutable reference to the kiosk where the item is being delisted from.
    /// @param tp The transfer policy associated with the listed item.
    /// @param item The ID of the item to be delisted from the kiosk.
    /// @param price The price of the item to be delisted (in mist unit).
    /// @param ctx The transaction context of the sender.
    public fun delist<T: key + store>(
        s_item_pc: SItemWithPurchaseCap<T>,
        kiosk_cap: &KioskOwnerCap,
        kiosk: &mut Kiosk,
        item: ID,
        ctx: &TxContext,
    ) {
        let SItemWithPurchaseCap<T> {
            id: s_id,
            kioskId: s_kioskId,
            purchaseCap,
            item_id: _,
            min_price: _,
            owner,
            royalty_fee: _,
            marketplace_fee: _,
        } = s_item_pc;
        let caller = tx_context::sender(ctx);
        assert!(caller == owner, ENotAuthorized);

        let kioskId = object::id(kiosk);
        let has_access = kiosk::has_access(kiosk, kiosk_cap);
        assert!(has_access, ENotAuthorized);
        let item_id = kiosk::purchase_cap_item<T>(&purchaseCap);

        // checks if the kioks are the same
        assert!(kioskId == s_kioskId, ENotSameKiosk);
        assert!(item_id == item, ENotSameItem);
        // return purchaseCap and delist the item
        kiosk::return_purchase_cap<T>(kiosk, purchaseCap);

        emit(ItemDelistedEvent {
            kiosk: kioskId,
            item: item_id,
            item_type: utils::type_to_string<T>(),
            shared_purchaseCap: object::uid_to_inner(&s_id),
            owner: tx_context::sender(ctx),
        });

        // delete the old purchase cap wrapper
        object::delete(s_id);
    }

    /// @dev This function facilitates the purchase of an item from a seller's kiosk. It ensures the buyer has
    ///      sufficient funds, verifies the item and kiosk details, processes the marketplace and royalty fees, and
    ///      transfers ownership of the item to the buyer. If applicable, it applies transfer policies to the item
    ///      and emits an event upon successful purchase.
    /// @param market A mutable reference to the marketplace handling balances and marketplace fees.
    /// @param buyers_kc The kiosk capability used to verify the buyer's access to their kiosk.
    /// @param buyers_kiosk A mutable reference to the buyer's kiosk where the purchased item will be placed or locked.
    /// @param sellers_kiosk A mutable reference to the seller's kiosk from which the item is being purchased.
    /// @param tp The transfer policy associated with the item, defining rules for ownership transfer.
    /// @param item The ID of the item being purchased from the seller's kiosk.
    /// @param item_purchase_cap A struct containing the purchase capability, item details, and pricing information.
    /// @param payment the buyer's payment coin used to pay for the item and associated fees.
    /// @param ctx The transaction context of the sender.
    /// @return TransferRequest<T> The transfer request for the item. After executing this function,
    /// the rules associated with the transfer policy must be collected and confirmed.
    #[allow(lint(self_transfer))]
    public fun buy<T: key + store>(
        market: &mut MarketPlace,
        buyers_kc: &KioskOwnerCap,
        buyers_kiosk: &mut Kiosk,
        sellers_kiosk: &mut Kiosk,
        tp: &mut TransferPolicy<T>,
        item: ID,
        item_purchase_cap: SItemWithPurchaseCap<T>,
        payment: Coin<SUI>,
        ctx: &mut TxContext,
    ): (TransferRequest<T>) {
        let spc_id = object::id(&item_purchase_cap);
        let SItemWithPurchaseCap<T> {
            id,
            kioskId: targetKiosk,
            purchaseCap,
            item_id: _,
            min_price: price,
            owner: _,
            royalty_fee,
            marketplace_fee,
        } = item_purchase_cap;

        let mut payment_balance = payment.into_balance();

        let pc_item: ID = purchaseCap.purchase_cap_item<T>();

        assert!(payment_balance.value() >= price + royalty_fee + marketplace_fee, ENotEnoughFunds);

        // checks if the kioks are the same and if the item seleted is the same
        assert!(targetKiosk == object::id(sellers_kiosk), ENotSameKiosk);
        assert!(pc_item == item, ENotSameItem);
        // checks if the buyer provided enough funds to buy the item
        let market_fee_coin = coin::take<SUI>(&mut payment_balance, marketplace_fee, ctx);
        let payment_coin = coin::take<SUI>(&mut payment_balance, price, ctx);
        market.add_balance(market_fee_coin);

        let (i, mut tr) = kiosk::purchase_with_cap<T>(sellers_kiosk, purchaseCap, payment_coin);
        emit(ItemBoughtEvent {
            kiosk: targetKiosk,
            item: pc_item,
            price: price,
            item_type: utils::type_to_string<T>(),
            shared_purchaseCap: spc_id,
            buyer: tx_context::sender(ctx),
        });
        id.delete();
        if (tp.has_rule<T, l_rule::Rule>()) {
            kiosk::lock<T>(buyers_kiosk, buyers_kc, tp, i);
            l_rule::prove(&mut tr, buyers_kiosk);
        } else {
            // kiosk::place<T>(buyers_kiosk, buyers_pkc, i);
            transfer::public_transfer(i, ctx.sender());
        };

        if (tp.has_rule<T, r_rule::Rule>()) {
            let royalty_fee_coin = coin::take<SUI>(&mut payment_balance, royalty_fee, ctx);
            r_rule::pay(tp, &mut tr, royalty_fee_coin);
        };
        if (tp.has_rule<T, floor_rule::Rule>()) {
            floor_rule::prove(tp, &mut tr);
        };
        let mut remaining_coin = coin::zero<SUI>(ctx);
        remaining_coin.balance_mut().join(payment_balance);
        transfer::public_transfer(remaining_coin, ctx.sender());
        tr
    }

    /// @dev This function finalizes the purchase process by confirming the transfer request for an item.
    ///      It ensures that all rules and policies associated with the item's transfer policy have been fulfilled
    ///      before completing the transfer.
    /// @notice This function must be called after the `buy` function to validate the transfer and complete the transaction.
    /// @param tr The transfer request generated during the purchase process, containing details of the item and transfer rules to be confirmed.
    /// @param tp A reference to the transfer policy associated with the item, which defines the rules and conditions for the transfer.
    public fun confirm_purchase<T: key + store>(tr: TransferRequest<T>, tp: &TransferPolicy<T>) {
        tp.confirm_request(tr);
    }

    // ==================== Getter Functions  ========================

    /// @dev Retrieves the minimum price of an item associated with its purchase capability.
    /// @param self A reference to the `SItemWithPurchaseCap` object containing the item's details.
    /// @return The minimum price of the item as a `u64` value.
    public fun get_price<T: key + store>(self: &SItemWithPurchaseCap<T>): u64 {
        self.min_price
    }

    /// @dev Calculates the total fee (marketplace fee + royalty fee) for an item associated with its purchase capability.
    /// @param self A reference to the `SItemWithPurchaseCap` object containing the item's details.
    /// @return The total fee for the item as a `u64` value.
    public fun get_fee_by_pc<T: key + store>(self: &SItemWithPurchaseCap<T>): u64 {
        self.marketplace_fee + self.royalty_fee
    }

    /// @dev Retrieves the owner address of an item associated with its purchase capability.
    /// @param self A reference to the `SItemWithPurchaseCap` object containing the item's details.
    /// @return The address of the item's owner.
    public fun get_owner<T: key + store>(self: &SItemWithPurchaseCap<T>): address {
        self.owner
    }

    /// @dev Retrieves the ID of an item associated with its purchase capability.
    /// @param self A reference to the `SItemWithPurchaseCap` object containing the item's details.
    /// @return The ID of the item as an `ID` type.
    public fun get_item_id<T: key + store>(self: &SItemWithPurchaseCap<T>): ID {
        self.item_id
    }

    /// @dev Retrieves the ID of the kiosk associated with an item's purchase capability.
    /// @param self A reference to the `SItemWithPurchaseCap` object containing the item's details.
    /// @return The ID of the kiosk as an `ID` type.
    public fun get_kiosk_id<T: key + store>(self: &SItemWithPurchaseCap<T>): ID {
        self.kioskId
    }

    /// @dev Retrieves the ID of the purchase capability associated with an item.
    /// @param self A reference to the `SItemWithPurchaseCap` object containing the item's details.
    /// @return The ID of the purchase capability as an `ID` type.
    public fun get_purchase_cap_id<T: key + store>(self: &SItemWithPurchaseCap<T>): ID {
        object::id(&self.purchaseCap)
    }

    /// @dev Emits an event when an item is listed in the marketplace.
    /// @param kiosk The ID of the kiosk where the item is listed.
    /// @param kiosk_cap The ID of the kiosk capability used for the listing.
    /// @param shared_purchaseCap The shared purchase capability ID associated with the item.
    /// @param item The ID of the listed item.
    /// @param price The listing price of the item (in mist units).
    /// @param marketplace_fee The fee charged by the marketplace for listing the item.
    /// @param owner The address of the owner listing the item.
    public(package) fun emit_listing_event(
        kiosk: ID,
        kiosk_cap: ID,
        shared_purchaseCap: ID,
        item: ID,
        item_type: String,
        price: u64,
        marketplace_fee: u64,
        owner: address,
    ) {
        emit(ItemListedEvent {
            kiosk,
            kiosk_cap,
            shared_purchaseCap,
            item,
            item_type,
            price,
            marketplace_fee,
            royalty_fee: 0,
            owner,
        });
    }

    /// @dev Emits an event when the details of a listed item are updated in the marketplace.
    /// @param kiosk The ID of the kiosk where the item is listed.
    /// @param kiosk_cap The ID of the kiosk capability used for the update.
    /// @param item The ID of the item being updated.
    /// @param shared_purchaseCap The shared purchase capability ID associated with the item.
    /// @param price The updated price of the item (in mist units).
    /// @param marketplace_fee The updated marketplace fee for the item.
    /// @param owner The address of the owner updating the listing.
    public(package) fun emit_update_event(
        kiosk: ID,
        kiosk_cap: ID,
        item: ID,
        item_type: String,
        shared_purchaseCap: ID,
        price: u64,
        marketplace_fee: u64,
        owner: address,
    ) {
        emit(ItemUpdatedEvent {
            kiosk,
            kiosk_cap,
            item,
            item_type,
            shared_purchaseCap,
            price,
            marketplace_fee,
            royalty_fee: 0,
            owner,
        });
    }

    /// @dev Emits an event when an item is delisted from the marketplace.
    /// @param kiosk The ID of the kiosk where the item was listed.
    /// @param item The ID of the delisted item.
    /// @param shared_purchaseCap The shared purchase capability ID associated with the item.
    /// @param owner The address of the owner delisting the item.
    public(package) fun emit_delist_event(
        kiosk: ID,
        item: ID,
        item_type: String,
        shared_purchaseCap: ID,
        owner: address,
    ) {
        emit(ItemDelistedEvent {
            kiosk,
            item,
            item_type,
            shared_purchaseCap,
            owner,
        });
    }

    /// @dev Emits an event when an item is purchased from the marketplace.
    /// @param kiosk The ID of the kiosk where the item was listed.
    /// @param item The ID of the purchased item.
    /// @param price The purchase price of the item (in mist units).
    /// @param shared_purchaseCap The shared purchase capability ID associated with the item.
    /// @param buyer The address of the buyer who purchased the item.
    public(package) fun emit_buy_event(
        kiosk: ID,
        item: ID,
        item_type: String,
        price: u64,
        shared_purchaseCap: ID,
        buyer: address,
    ) {
        emit(ItemBoughtEvent {
            kiosk,
            item,
            item_type,
            price,
            shared_purchaseCap,
            buyer,
        });
    }
}
