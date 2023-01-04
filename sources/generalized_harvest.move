module satay_liquidswap_harvest::stapt_apt_farming {
    use std::signer;
    use std::string;
    use std::option;

    use aptos_framework::coin::{Self, Coin, MintCapability, BurnCapability, FreezeCapability};
    use aptos_framework::account::{Self, SignerCapability};

    use satay::math::{mul_u128_u64_div_u64_result_u64, calculate_proportion_of_u64_with_u128_denominator};

    use harvest::stake;

    struct FarmingAccount has key {
        signer_cap: SignerCapability,
        manager_address: address,
        new_manager_address: address
    }

    // coin issued upon apply_position
    struct LiquidswapHarvestCoin<phantom S, phantom R> {}

    struct LiquidswapHarvestCoinCaps<phantom S, phantom R> has key {
        mint_cap: MintCapability<LiquidswapHarvestCoin<S, R>>,
        burn_cap: BurnCapability<LiquidswapHarvestCoin<S, R>>,
        freeze_cap: FreezeCapability<LiquidswapHarvestCoin<S, R>>
    }

    const ERR_NOT_ADMIN: u64 = 1;
    const ERR_SLIPPAGE_TOLERANCE_BPS_TOO_HIGH: u64 = 2;

    // entry functions

    // deployer functions

    // initialize resource account and DittoFarmingCoin
    // register LP<APT, stAPT> and AptosCoin for resource account
    public entry fun initialize<S, R>(manager: &signer) {
        // only module publisher can initialize
        let manager_address = signer::address_of(manager);
        assert!(manager_address == @satay_liquidswap_harvest, ERR_NOT_ADMIN);

        // create resource account and store its SignerCapability in the manager's account
        let (farming_acc, signer_cap) = account::create_resource_account(
            manager,
            b"liquidswap_farming_product"
        );
        move_to(manager, FarmingAccount {
            signer_cap,
            manager_address,
            new_manager_address: @0x0
        });

        // initailze DittoFarmingCoin
        // store mint, burn and freeze capabilities in the resource account
        let (
            burn_cap,
            freeze_cap,
            mint_cap
        ) = coin::initialize<LiquidswapHarvestCoin<S, R>>(
            manager,
            string::utf8(b"Ditto Farming Coin"),
            string::utf8(b"DFC"),
            coin::decimals<S>(),
            true
        );
        move_to(
            &farming_acc,
            LiquidswapHarvestCoinCaps<S, R> {
                mint_cap,
                burn_cap,
                freeze_cap
            }
        );

        coin::register<S>(&farming_acc);
    }

    // manager functions

    public entry fun set_manager_address(
        manager: &signer,
        new_manager_address: address
    ) acquires FarmingAccount {
        let farming_acc = borrow_global_mut<FarmingAccount>(@satay_liquidswap_harvest);
        assert!(farming_acc.manager_address == signer::address_of(manager), ERR_NOT_ADMIN);
        farming_acc.new_manager_address = new_manager_address;
    }

    public entry fun accept_new_manager(new_manager: &signer) acquires FarmingAccount {
        let farming_acc = borrow_global_mut<FarmingAccount>(@satay_liquidswap_harvest);
        assert!(farming_acc.new_manager_address == signer::address_of(new_manager), ERR_NOT_ADMIN);
        farming_acc.manager_address = farming_acc.new_manager_address;
        farming_acc.new_manager_address = @0x0;
    }

    // user functions

    // deposit amount of AptosCoin into the product
    // mints DittoFarmingCoin and deposits to caller account
    // called by users
    public entry fun deposit<S, R>(
        user: &signer,
        pool_address: address,
        amount: u64
    ) acquires FarmingAccount, LiquidswapHarvestCoinCaps {
        let user_addr = signer::address_of(user);

        if(!coin::is_account_registered<LiquidswapHarvestCoin<S, R>>(user_addr)){
            coin::register<LiquidswapHarvestCoin<S, R>>(user);
        };

        let lp_coins = coin::withdraw<S>(user, amount);
        let product_coins = apply_position<S, R>(pool_address, lp_coins);

        coin::deposit(signer::address_of(user), product_coins);
    }

    // withdraw amount of DittoFarmCoin from the user
    // burn DittoFarmingCoin and deposit returned AptosCoin to caller account
    // called by users
    public entry fun withdraw<S, R>(
        user: &signer,
        pool_address: address,
        amount: u64
    ) acquires FarmingAccount, LiquidswapHarvestCoinCaps {
        let product_coins = coin::withdraw<LiquidswapHarvestCoin<S, R>>(user, amount);
        let lp_coins = liquidate_position<S, R>(pool_address, product_coins);
        coin::deposit<S>(signer::address_of(user), lp_coins);
    }

    // calls reinvest_returns for user
    // deposit returned DittoFarmingCoin and AptosCoin to user account
    public entry fun tend<S, R>(
        manager: &signer,
        pool_address: address
    ) acquires FarmingAccount {
        let manager_addr = signer::address_of(manager);
        let farming_acc = borrow_global_mut<FarmingAccount>(@satay_liquidswap_harvest);
        assert!(farming_acc.manager_address == manager_addr, ERR_NOT_ADMIN);
        reinvest_returns<S, R>(pool_address);
    }

    // coin operators

    // mint DittoFarmingCoin for AptosCoin
    public fun apply_position<S, R>(
        pool_address: address,
        lp_coins: Coin<S>,
    ): Coin<LiquidswapHarvestCoin<S, R>> acquires FarmingAccount, LiquidswapHarvestCoinCaps {
        let deposit_amount = coin::value(&lp_coins);
        if(deposit_amount > 0){
            let ditto_farming_account = borrow_global<FarmingAccount>(@satay_liquidswap_harvest);
            let ditto_farming_signer = account::create_signer_with_capability(&ditto_farming_account.signer_cap);
            let ditto_farming_address = signer::address_of(&ditto_farming_signer);

            let mint_amount = get_mint_amount_for_stake_amount<S, R>(
                deposit_amount,
                pool_address,
                ditto_farming_address
            );
            stake::stake<S, R>(&ditto_farming_signer, pool_address, lp_coins);

            let caps = borrow_global<LiquidswapHarvestCoinCaps<S, R>>(@satay_liquidswap_harvest);
            coin::mint(mint_amount, &caps.mint_cap)
        } else {
            coin::destroy_zero(lp_coins);
            coin::zero()
        }
    }

    // liquidates DittoFarmingCoin for AptosCoin
    public fun liquidate_position<S, R>(
        pool_address: address,
        product_coins: Coin<LiquidswapHarvestCoin<S, R>>,
    ): Coin<S> acquires FarmingAccount, LiquidswapHarvestCoinCaps {
        let ditto_farming_account = borrow_global<FarmingAccount>(@satay_liquidswap_harvest);
        let ditto_farming_signer = account::create_signer_with_capability(&ditto_farming_account.signer_cap);
        let ditto_farming_address = signer::address_of(&ditto_farming_signer);

        let burn_amount = coin::value(&product_coins);
        if(burn_amount > 0){
            let unstake_amount = get_unstake_amount_for_burn_amount<S, R>(
                burn_amount,
                pool_address,
                ditto_farming_address
            );

            let caps = borrow_global<LiquidswapHarvestCoinCaps<S, R>>(@satay_liquidswap_harvest);
            coin::burn(product_coins, &caps.burn_cap);

            stake::unstake<S, R>(&ditto_farming_signer, pool_address, unstake_amount)
        } else {
            coin::destroy_zero(product_coins);
            coin::zero()
        }
    }

    public fun reinvest_returns<S, R>(
        pool_address: address,
    ) acquires FarmingAccount {
        let ditto_farming_account = borrow_global<FarmingAccount>(@satay_liquidswap_harvest);
        let ditto_farming_signer = account::create_signer_with_capability(&ditto_farming_account.signer_cap);
        let reward_coins = stake::harvest<S, R>(&ditto_farming_signer, pool_address);
        let lp_coins = convert_rewards_to_lp_coins<S, R>(reward_coins);
        stake::stake<S, R>(&ditto_farming_signer, pool_address, lp_coins);
    }

    // private functions

    fun convert_rewards_to_lp_coins<S, R>(
        reward_coins: Coin<R>,
    ): Coin<S> {
        coin::destroy_zero(reward_coins);
        coin::zero<S>()
    }

    // getter functions

    public fun get_mint_amount_for_stake_amount<S, R>(
        stake_amount: u64,
        pool_address: address,
        account_address: address
    ): u64 {
        let harvest_coin_supply = option::get_with_default(&coin::supply<LiquidswapHarvestCoin<S, R>>(), 0);
        let total_staked_amount = stake::get_user_stake<S, R>(pool_address, account_address);
        mul_u128_u64_div_u64_result_u64(harvest_coin_supply, stake_amount, total_staked_amount)
    }

    public fun get_unstake_amount_for_burn_amount<S, R>(
        burn_amount: u64,
        pool_address: address,
        account_address: address
    ): u64 {
        let harvest_coin_supply = option::get_with_default(&coin::supply<LiquidswapHarvestCoin<S, R>>(), 0);
        let total_staked_amount = stake::get_user_stake<S, R>(pool_address, account_address);
        calculate_proportion_of_u64_with_u128_denominator(total_staked_amount, burn_amount, harvest_coin_supply)
    }

    public fun get_manager_address(): address acquires FarmingAccount {
        let farming_account = borrow_global<FarmingAccount>(@satay_liquidswap_harvest);
        farming_account.manager_address
    }
}
