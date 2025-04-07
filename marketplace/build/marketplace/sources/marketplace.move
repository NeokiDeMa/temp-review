module marketplace::marketplace {
    use access_control::access_control::{Self as a_c, OwnerCap, has_cap_access, SRoles, RoleCap};
    use kiosk::personal_kiosk as PKiosk;
    use marketplace::utils::type_to_string;
    use std::string::{String, utf8};
    use sui::{
        balance::{Self, Balance},
        coin::{Self, Coin},
        dynamic_object_field,
        event::emit,
        kiosk,
        package,
        sui::SUI,
        vec_map::{Self as map, VecMap}
    };

    public struct MARKETPLACE has drop {}

    public struct MarketPlace has key {
        id: UID,
        // Name of the marketplace
        name: String,
        // Base fee for the marketplace in percentage 100 = 1%
        baseFee: u16,
        // Personal fee for each user in percentage 100 = 1%, 10000 = 100%
        personalFee: VecMap<address, u16>,
        // Store PurchaseCap for each store
        balance: Balance<SUI>,
    }

    public struct AdminCap has key, store {
        id: UID,
    }

    public struct OfferCap has key {
        id: UID,
        offer: ID,
        itemType: String,
    }

    public struct Receipt has key {
        id: UID,
        offer_cap: ID,
        itemType: String,
    }

    // ==================== Error Codes ========================
    const ENotAuthorized: u64 = 400;
    const ENotEnoughFunds: u64 = 403;
    const ENotSameLength: u64 = 404;
    const ENotSameType: u64 = 405;
    const ENotSameId: u64 = 406;

    // ==================== Events ========================

    public struct KioskCreatedEvent has copy, drop {
        kiosk: ID,
        personal_kiosk_cap: ID,
        owner: address,
    }

    public struct PersonalFeeSetEvent has copy, drop {
        recipient: vector<address>,
        fee: vector<u16>,
    }

    public struct ReceiptCreatedEvent has copy, drop {
        receipt_id: ID,
        offer_cap: ID,
    }

    public struct ReceiptDestroyedEvent has copy, drop {
        receipt_id: ID,
        offer_cap: ID,
    }

    fun init(otw: MARKETPLACE, ctx: &mut TxContext) {
        let new_marketplace = object::new(ctx);
        transfer::share_object(MarketPlace {
            id: new_marketplace,
            name: utf8(b"Hokko"),
            baseFee: 200, // 2%
            personalFee: map::empty(),
            balance: balance::zero(),
        });
        a_c::default<MARKETPLACE>(&otw, ctx);
        package::claim_and_keep(otw, ctx);
    }

    /// @dev This function creates a new kiosk along with a personal kiosk capability (PersonalKioskCap).
    ///      It sets the kiosk owner, transfers ownership of the kiosk capability to the sender, and emits a KioskCreatedEvent.
    /// @notice This function does not store the created kiosk information in the marketplace. It simply creates a kiosk.
    /// @param ctx The transaction context of the sender.
    /// @return (ID, ID) Return created kiosk and personal kiosk cap ids
    #[allow(lint(self_transfer))]
    public fun create_kiosk(ctx: &mut TxContext): (ID, ID) {
        let (mut kiosk, kioskCap) = kiosk::new(ctx);
        let kioskId = object::id(&kiosk);
        kiosk::set_owner(&mut kiosk, &kioskCap, ctx);

        let personal_kiosk_cap = PKiosk::new(&mut kiosk, kioskCap, ctx);
        let pkc_id = object::id(&personal_kiosk_cap);

        transfer::public_share_object(kiosk);
        PKiosk::transfer_to_sender(personal_kiosk_cap, ctx);
        emit(KioskCreatedEvent {
            kiosk: kioskId,
            personal_kiosk_cap: pkc_id,
            owner: tx_context::sender(ctx),
        });
        (kioskId, pkc_id)
    }

    public fun destroy_receipt(cap: OfferCap, receipt: Receipt) {
        let OfferCap {
            id: offer_cap_id,
            offer: _,
            itemType: offer_cap_type,
        } = cap;
        let Receipt {
            id: receipt_id,
            offer_cap: receipt_offer_cap,
            itemType: receipt_item_type,
        } = receipt;
        assert!(offer_cap_type == receipt_item_type, ENotSameType);
        assert!(offer_cap_id.to_inner() == receipt_offer_cap, ENotSameType);
        emit(ReceiptDestroyedEvent {
            receipt_id: receipt_id.to_inner(),
            offer_cap: offer_cap_id.to_inner(),
        });

        receipt_id.delete();
        offer_cap_id.delete();
    }

    // ==================== Admin Functions  ========================
    /// @dev Sets a personalized fee rate for a recipient in the marketplace.
    /// @param self A mutable reference to the `MarketPlace` object where the fee is being configured.
    /// @param admin A reference to the `AdminCap` role capability for verifying administrative access.
    /// @param roles A reference to the roles object that stores the administrative permissions for the marketplace.
    /// @param recipient A vector of addresses representing the recipients to which the fees will be assigned.
    /// @param fee The fee rate (in basis points, where 1% = 100 basis points) to be applied to the recipient's transactions.
    public fun set_personal_fee(
        self: &mut MarketPlace,
        admin: &RoleCap<AdminCap>,
        roles: &SRoles<MARKETPLACE>,
        recipient: vector<address>,
        fee: vector<u16>,
    ) {
        assert!(has_cap_access<MARKETPLACE, AdminCap>(roles, admin), ENotAuthorized);
        assert!(recipient.length() == fee.length(), ENotSameLength);

        let mut i = 0;
        while (i < recipient.length()) {
            if (map::contains<address, u16>(&self.personalFee, &recipient[i])) {
                let old_fee = map::get_mut<address, u16>(&mut self.personalFee, &recipient[i]);
                *old_fee = fee[i];
                i = i + 1;
            } else {
                map::insert(&mut self.personalFee, recipient[i], fee[i]);
                i = i + 1;
            };
        };
        emit(PersonalFeeSetEvent {
            recipient: recipient,
            fee: fee,
        });
    }

    /// @dev Updates the base fee for all marketplace transactions. Only authorized administrators can call this function.
    /// @param self A mutable reference to the `MarketPlace` object where the base fee will be updated.
    /// @param admin A reference to the `AdminCap` role capability for verifying administrative access.
    /// @param roles A reference to the roles object that stores the administrative permissions for the marketplace.
    /// @param fee The new base fee rate (in basis points, where 1% = 100 basis points) to be applied.
    public fun set_base_fee(
        self: &mut MarketPlace,
        admin: &RoleCap<AdminCap>,
        roles: &SRoles<MARKETPLACE>,
        fee: u16,
    ) {
        assert!(has_cap_access<MARKETPLACE, AdminCap>(roles, admin), ENotAuthorized);
        self.baseFee = fee;
    }

    /// @dev Grants administrative privileges to the specified recipient. Only the marketplace owner can add new administrators.
    /// @param owner A reference to the `OwnerCap` of the marketplace, used to verify ownership and authority.
    /// @param roles A mutable reference to the roles object where the recipient will be granted administrative privileges.
    /// @param recipient The address of the recipient who will be assigned the `AdminCap`.
    /// @param ctx Sender's tx context.
    public fun add_admin(
        owner: &OwnerCap<MARKETPLACE>,
        roles: &mut SRoles<MARKETPLACE>,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        a_c::add_role<MARKETPLACE, AdminCap>(owner, roles, recipient, ctx);
    }

    /// @dev Revokes administrative privileges from a specified administrator. Only the marketplace owner can perform this action.
    /// @param _ A reference to the `OwnerCap` of the marketplace, used to verify ownership and authority.
    /// @param roles A mutable reference to the roles object from which the target administrator's privileges will be removed.
    /// @param target The ID of the administrator whose privileges are to be revoked.
    /// @param ctx Sender's tx context.
    public fun revoke_admin(
        _: &OwnerCap<MARKETPLACE>,
        roles: &mut SRoles<MARKETPLACE>,
        target: ID,
        ctx: &mut TxContext,
    ) {
        a_c::revoke_role_access<MARKETPLACE>(_, roles, target, ctx)
    }

    /// @dev Allows an administrator to withdraw a specified amount of profit from the marketplace's balance.
    /// @notice If no amount is specified, the entire balance is withdrawn.
    /// @param admin A reference to the `AdminCap` role capability to verify administrative access.
    /// @param roles A reference to the roles of the marketplace, used to check authorization.
    /// @param self A mutable reference to the `MarketPlace` object from which the profit is being withdrawn.
    /// @param amount An optional `u64` value specifying the amount to withdraw. If not provided, the full balance is withdrawn.
    /// @param recipient The address of the recipient to whom the withdrawn funds will be transferred.
    /// @param ctx Sender's tx context.
    public fun withdraw_profit(
        admin: &RoleCap<AdminCap>,
        roles: &SRoles<MARKETPLACE>,
        self: &mut MarketPlace,
        amount: Option<u64>,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        assert!(has_cap_access<MARKETPLACE, AdminCap>(roles, admin), ENotAuthorized);
        let amount = if (amount.is_some()) {
            let amt = amount.destroy_some();
            assert!(amt <= self.balance.value(), ENotEnoughFunds);
            amt
        } else {
            self.balance.value()
        };

        let coin = coin::take<SUI>(&mut self.balance, amount, ctx);
        transfer::public_transfer(coin, recipient);
    }

    /// @dev Adds the specified payment amount to the marketplace's balance.
    /// @param self A mutable reference to the `MarketPlace` object where the balance will be updated.
    /// @param payment A `Coin<SUI>` representing the SUI coin object to be added to the marketplace's balance.
    public fun add_balance(self: &mut MarketPlace, payment: Coin<SUI>) {
        coin::put<SUI>(&mut self.balance, payment);
    }

    /// @dev Retrieves the current balance of the marketplace. Only accessible to authorized administrators.
    /// @param self A reference to the `MarketPlace` object containing the balance details.
    /// @param roles A reference to the roles object verifying administrative access.
    /// @param admin A reference to the `AdminCap` role capability for access validation.
    /// @return The current balance of the marketplace as a `u64` value.
    public fun get_balance(
        self: &MarketPlace,
        roles: &SRoles<MARKETPLACE>,
        admin: &RoleCap<AdminCap>,
    ): u64 {
        assert!(has_cap_access<MARKETPLACE, AdminCap>(roles, admin), ENotAuthorized);
        self.balance.value()
    }

    /// @dev Retrieves the fee applicable to a specific owner in the marketplace. If a personal fee exists for the owner, it is returned; otherwise, the base fee is used.
    /// @param self A reference to the `MarketPlace` object containing the fee configuration.
    /// @param owner The address of the owner whose fee is being queried.
    /// @return The applicable fee as a `u16` value.

    public fun get_fee(self: &MarketPlace, owner: address): u16 {
        let personal_fee_exists = map::contains<address, u16>(&self.personalFee, &owner);

        if (personal_fee_exists) {
            let personal_fee = *map::get<address, u16>(&self.personalFee, &owner);
            if (personal_fee >= self.baseFee) {
                return self.baseFee
            } else {
                return personal_fee
            }
        };
        self.baseFee
    }

    // ==================== Package-Public Functions  ========================

    /// @dev Adds a key-value pair to the marketplace's dynamic object fields.
    /// @notice Use this function only to store important information related to trading
    /// @param market A mutable reference to the `MarketPlace` object where the key-value pair will be added.
    /// @param name The key  used to identify the value in the marketplace.
    /// @param value The object value associated with the given key.
    public(package) fun add_to_marketplace<Name: copy + drop + store, Value: key + store>(
        market: &mut MarketPlace,
        name: Name,
        value: Value,
    ) {
        dynamic_object_field::add(&mut market.id, name, value);
    }

    /// @dev Removes a key-value pair from the marketplace's dynamic object fields and retrieves the value associated with the given key.
    /// @param market A mutable reference to the `MarketPlace` object where the key-value pair will be removed.
    /// @param name The key identifying the value to be removed.
    public(package) fun remove_from_marketplace<Name: copy + drop + store, Value: key + store>(
        market: &mut MarketPlace,
        name: Name,
    ): Value {
        dynamic_object_field::remove(&mut market.id, name)
    }

    public(package) fun create_offer_cap<T>(offer_id: ID, ctx: &mut TxContext): OfferCap {
        let offer_cap = OfferCap {
            id: object::new(ctx),
            offer: offer_id,
            itemType: type_to_string<T>(),
        };
        offer_cap
    }

    public(package) fun transfer_offer_cap(self: OfferCap, ctx: &TxContext) {
        transfer::transfer(self, ctx.sender());
    }

    public(package) fun create_receipt<T: key + store>(
        offer_cap: ID,
        recipient: address,
        ctx: &mut TxContext,
    ) {
        let receipt = Receipt {
            id: object::new(ctx),
            offer_cap,
            itemType: type_to_string<T>(),
        };
        emit(ReceiptCreatedEvent {
            receipt_id: object::id(&receipt),
            offer_cap,
        });
        transfer::transfer(receipt, recipient);
    }

    public(package) fun delete_cap(self: OfferCap) {
        let OfferCap { id, .. } = self;
        id.delete();
    }

    // =================== Assertions ========================

    public(package) fun assert_offer_match(cap: &OfferCap, offer_id: ID) {
        assert!(cap.offer == offer_id, ENotSameId);
    }

    /// @dev Execute init() for test.
    /// @param ctx Sender's tx context.
    #[test_only]
    public(package) fun init_test(ctx: &mut TxContext) {
        let otw = MARKETPLACE {};
        init(otw, ctx);
    }
}
