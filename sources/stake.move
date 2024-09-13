module stake::stake {
    use std::signer;
    use std::string::{Self, String};
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::timestamp;
    use aptos_framework::account;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::resource_account;
    use aptos_std::table::{Self, Table};
    use aptos_std::type_info;

    // Error codes
    const ERROR_ONLY_ADMIN: u64 = 0;
    const ERROR_POOL_EXIST: u64 = 1;
    const ERROR_COIN_NOT_EXIST: u64 = 2;
    const ERROR_PASS_START_TIME: u64 = 3;
    const ERROR_AMOUNT_TOO_SMALL: u64 = 4;
    const ERROR_POOL_LIMIT_ZERO: u64 = 5;
    const ERROR_INSUFFICIENT_BALANCE: u64 = 6;
    const ERROR_POOL_NOT_EXIST: u64 = 7;
    const ERROR_STAKE_ABOVE_LIMIT: u64 = 8;
    const ERROR_NO_STAKE: u64 = 9;
    const ERROR_NO_LIMIT_SET: u64 = 10;
    const ERROR_LIMIT_MUST_BE_HIGHER: u64 = 11;
    const ERROR_POOL_STARTED: u64 = 12;
    const ERROR_END_TIME_EARLIER_THAN_START_TIME: u64 = 13;
    const ERROR_POOL_END: u64 = 14;
    const ERROR_REWARD_MAX: u64 = 16;
    const ERROR_WRONG_SIGNER: u64 = 17;
    const ERROR_SAME_TOKEN: u64 = 18;
    const ERROR_USER_REGISTERED: u64 = 19;

    struct StakeOwnerCap has key {
        admin: address,
    }

    struct PoolInfo<phantom StakeToken, phantom RewardToken> has key {
        total_staked_token: u64,
        total_reward_token: u64,
        reward_per_second: u64,
        start_timestamp: u64,
        end_timestamp: u64,
        last_reward_timestamp: u64,
        seconds_for_user_limit: u64,
        pool_limit_per_user: u64,
        acc_token_per_share: u128,
        precision_factor: u128,
        users: Table<address, UserRegistry<StakeToken, RewardToken>>,
    }

    struct Pools has key {
        quantity: u64,
        pools: Table<String, bool>,
    }

    struct ListedPool<phantom StakeToken, phantom RewardToken> has key, store {
        coin_type: String,
        symbol: String,
        logo_url: String,
        decimals: u64,
        reward_per_second: u64,
        start_timestamp: u64,
        end_timestamp: u64,
        pool_limit_per_user: u64,
        seconds_for_user_limit: u64,
    }

    struct UserInfo<phantom StakeToken, phantom RewardToken> has key {
        amount: u64,
        reward_debt: u128,
        total_rewards_earned: u64,
    }

    struct UserRegistry<phantom StakeToken, phantom RewardToken> has store {
        user: address
    }

    // Events
    struct Events has key {
        create_pool_events: EventHandle<CreatePoolEvent>,
        deposit_events: EventHandle<DepositEvent>,
        withdraw_events: EventHandle<WithdrawEvent>,
        emergency_withdraw_events: EventHandle<EmergencyWithdrawEvent>,
        emergency_withdraw_reward_events: EventHandle<EmergencyWithdrawRewardEvent>,
        stop_reward_events: EventHandle<StopRewardEvent>,
        new_pool_limit_events: EventHandle<NewPoolLimitEvent>,
        new_reward_per_second_events: EventHandle<NewRewardPerSecondEvent>,
        new_start_and_end_timestamp_events: EventHandle<NewStartAndEndTimestampEvent>,
    }

    struct CreatePoolEvent has drop, store {
        user: address,
        stake_token_info: String,
        reward_token_info: String,
    }

    struct DepositEvent has drop, store {
        amount: u64,
    }

    struct WithdrawEvent has drop, store {
        amount: u64,
    }

    struct EmergencyWithdrawEvent has drop, store {
        amount: u64,
    }

    struct EmergencyWithdrawRewardEvent has drop, store {
        admin: address,
        amount: u64,
    }

    struct StopRewardEvent has drop, store {
        timestamp: u64
    }

    struct NewPoolLimitEvent has drop, store {
        pool_limit_per_user: u64
    }

    struct NewRewardPerSecondEvent has drop, store {
        reward_per_second: u64
    }

    struct NewStartAndEndTimestampEvent has drop, store {
        start_timestamp: u64,
        end_timestamp: u64,
    }

    // Initialize module
    fun init_module(resource_account: &signer) {
        move_to(resource_account, StakeOwnerCap {
            admin: @staking,
        });

        move_to(resource_account, Pools {
            quantity: 0,
            pools: table::new(),
        });

        move_to(resource_account, Events {
            create_pool_events: account::new_event_handle<CreatePoolEvent>(resource_account),
            deposit_events: account::new_event_handle<DepositEvent>(resource_account),
            withdraw_events: account::new_event_handle<WithdrawEvent>(resource_account),
            emergency_withdraw_events: account::new_event_handle<EmergencyWithdrawEvent>(resource_account),
            emergency_withdraw_reward_events: account::new_event_handle<EmergencyWithdrawRewardEvent>(resource_account),
            stop_reward_events: account::new_event_handle<StopRewardEvent>(resource_account),
            new_pool_limit_events: account::new_event_handle<NewPoolLimitEvent>(resource_account),
            new_reward_per_second_events: account::new_event_handle<NewRewardPerSecondEvent>(resource_account),
            new_start_and_end_timestamp_events: account::new_event_handle<NewStartAndEndTimestampEvent>(resource_account),
        });
    }

    public entry fun create_pool<StakeToken, RewardToken>(
        admin: &signer,
        symbol: vector<u8>,
        decimals: u64,
        logo_url: vector<u8>,
        reward_per_second: u64,
        start_timestamp: u64,
        end_timestamp: u64,
        pool_limit_per_user: u64,
        seconds_for_user_limit: u64,
    ) acquires StakeOwnerCap, Pools, Events {
        let admin_address = signer::address_of(admin);
        let cap = borrow_global<StakeOwnerCap>(@staking);
        assert!(admin_address == cap.admin, ERROR_ONLY_ADMIN);

        let now = timestamp::now_milliseconds();
        assert!(start_timestamp >= now, ERROR_PASS_START_TIME);
        assert!(start_timestamp < end_timestamp, ERROR_END_TIME_EARLIER_THAN_START_TIME);
        assert!(type_info::type_of<StakeToken>() != type_info::type_of<RewardToken>(), ERROR_SAME_TOKEN);

        if (seconds_for_user_limit > 0) {
            assert!(pool_limit_per_user > 0, ERROR_POOL_LIMIT_ZERO);
        };

        let precision_factor = math::pow(10, 9 - decimals);

        let pool = PoolInfo<StakeToken, RewardToken> {
            total_staked_token: 0,
            total_reward_token: 0,
            reward_per_second,
            last_reward_timestamp: start_timestamp,
            start_timestamp,
            end_timestamp,
            seconds_for_user_limit,
            pool_limit_per_user,
            acc_token_per_share: 0,
            precision_factor,
            users: table::new(),
        };

        let stake_token_info = type_info::type_name<StakeToken>();
        let reward_token_info = type_info::type_name<RewardToken>();

        let pools = borrow_global_mut<Pools>(@staking);
        let pool_key = string::utf8(b"pool_");
        string::append(&mut pool_key, stake_token_info);
        string::append(&mut pool_key, string::utf8(b"_"));
        string::append(&mut pool_key, reward_token_info);

        assert!(!table::contains(&pools.pools, pool_key), ERROR_POOL_EXIST);
        table::add(&mut pools.pools, pool_key, true);
        pools.quantity = pools.quantity + 1;

        move_to(admin, pool);

        let listed_pool = ListedPool<StakeToken, RewardToken> {
            coin_type: reward_token_info,
            symbol: string::utf8(symbol),
            logo_url: string::utf8(logo_url),
            decimals,
            reward_per_second,
            start_timestamp,
            end_timestamp,
            pool_limit_per_user,
            seconds_for_user_limit,
        };

        move_to(admin, listed_pool);

        let events = borrow_global_mut<Events>(@staking);
        event::emit_event(&mut events.create_pool_events, CreatePoolEvent {
            user: admin_address,
            stake_token_info,
            reward_token_info,
        });
    }

    public entry fun add_reward<StakeToken, RewardToken>(
        admin: &signer,
        amount: u64,
    ) acquires StakeOwnerCap, PoolInfo {
        let admin_address = signer::address_of(admin);
        let cap = borrow_global<StakeOwnerCap>(@staking);
        assert!(admin_address == cap.admin, ERROR_ONLY_ADMIN);

        let pool = borrow_global_mut<PoolInfo<StakeToken, RewardToken>>(@staking);
        
        let reward_coins = coin::withdraw<RewardToken>(admin, amount);
        let reward_amount = coin::value(&reward_coins);
        coin::deposit(@staking, reward_coins);

        pool.total_reward_token = pool.total_reward_token + reward_amount;
    }

    public entry fun deposit<StakeToken, RewardToken>(
        account: &signer,
        amount: u64,
    ) acquires PoolInfo, Events, UserInfo {
        let account_address = signer::address_of(account);
        let pool = borrow_global_mut<PoolInfo<StakeToken, RewardToken>>(@staking);
        
        let now = timestamp::now_milliseconds();
        assert!(pool.end_timestamp > now, ERROR_POOL_END);

        update_pool(pool, now);

        if (!exists<UserInfo<StakeToken, RewardToken>>(account_address)) {
            move_to(account, UserInfo<StakeToken, RewardToken> {
                amount: 0,
                reward_debt: 0,
                total_rewards_earned: 0,
            });
        };

        let user_info = borrow_global_mut<UserInfo<StakeToken, RewardToken>>(account_address);

        assert!(((user_info.amount + amount) <= pool.pool_limit_per_user) || (now >= (pool.start_timestamp + pool.seconds_for_user_limit)), ERROR_STAKE_ABOVE_LIMIT);

        if (user_info.amount > 0) {
            let pending_reward = cal_pending_reward(user_info.amount, user_info.reward_debt, pool.acc_token_per_share, pool.precision_factor);
            if (pending_reward > 0) {
                let reward_coins = coin::withdraw<RewardToken>(&@staking, pending_reward);
                coin::deposit(account_address, reward_coins);
                user_info.total_rewards_earned = user_info.total_rewards_earned + pending_reward;
            }
        };

        let stake_coins = coin::withdraw<StakeToken>(account, amount);
        coin::deposit(@staking, stake_coins);

        pool.total_staked_token = pool.total_staked_token + amount;
        user_info.amount = user_info.amount + amount;
        user_info.reward_debt = reward_debt(user_info.amount, pool.acc_token_per_share, pool.precision_factor);

        let events = borrow_global_mut<Events>(@staking);
        event::emit_event(&mut events.deposit_events, DepositEvent { amount });
    }

    public entry fun withdraw<StakeToken, RewardToken>(
        account: &signer,
        amount: u64,
    ) acquires PoolInfo, Events, UserInfo {
        let account_address = signer::address_of(account);
        let pool = borrow_global_mut<PoolInfo<StakeToken, RewardToken>>(@staking);
        
        let now = timestamp::now_milliseconds();
        update_pool(pool, now);

        let user_info = borrow_global_mut<UserInfo<StakeToken, RewardToken>>(account_address);
        assert!(user_info.amount >= amount, ERROR_INSUFFICIENT_BALANCE);

        let pending_reward = cal_pending_reward(user_info.amount, user_info.reward_debt, pool.acc_token_per_share, pool.precision_factor);

        if (amount > 0) {
            user_info.amount = user_info.amount - amount;
            pool.total_staked_token = pool.total_staked_token - amount;

            let stake_coins = coin::withdraw<StakeToken>(&@staking, amount);
            coin::deposit(account_address, stake_coins);
        };

        if (pending_reward > 0) {
            let reward_coins = coin::withdraw<RewardToken>(&@staking, pending_reward);
            coin::deposit(account_address, reward_coins);
            user_info.total_rewards_earned = user_info.total_rewards_earned + pending_reward;
        };

        user_info.reward_debt = reward_debt(user_info.amount, pool.acc_token_per_share, pool.precision_factor);

        let events = borrow_global_mut<Events>(@staking);
        event::emit_event(&mut events.withdraw_events, WithdrawEvent { amount });
    }

    public entry fun emergency_withdraw<StakeToken, RewardToken>(
        account: &signer,
    ) acquires PoolInfo, Events, UserInfo {
        let account_address = signer::address_of(account);
        let pool = borrow_global_mut<PoolInfo<StakeToken, RewardToken>>(@staking);
        let user_info = borrow_global_mut<UserInfo<StakeToken, RewardToken>>(account_address);

        let amount = user_info.amount;
        assert!(amount > 0, ERROR_INSUFFICIENT_BALANCE);

        user_info.amount = 0;
        user_info.reward_debt = 0;
        pool.total_staked_token = pool.total_staked_token - amount;

        let stake_coins = coin::withdraw<StakeToken>(&@staking, amount);
        coin::deposit(account_address, stake_coins);

        let events = borrow_global_mut<Events>(@staking);
        event::emit_event(&mut events.emergency_withdraw_events, EmergencyWithdrawEvent { amount });
    }

    public entry fun emergency_reward_withdraw<StakeToken, RewardToken>(
        admin: &signer,
    ) acquires StakeOwnerCap, PoolInfo, Events {
        let admin_address = signer::address_of(admin);
        let cap = borrow_global<StakeOwnerCap>(@staking);
        assert!(admin_address == cap.admin, ERROR_ONLY_ADMIN);

        let pool = borrow_global_mut<PoolInfo<StakeToken, RewardToken>>(@staking);
        let reward = pool.total_reward_token;
        assert!(reward > 0, ERROR_INSUFFICIENT_BALANCE);

        pool.total_reward_token = 0;
        let reward_coins = coin::withdraw<RewardToken>(&@staking, reward);
        coin::deposit(admin_address, reward_coins);

        let events = borrow_global_mut<Events>(@staking);
        event::emit_event(&mut events.emergency_withdraw_reward_events, EmergencyWithdrawRewardEvent {
            admin: admin_address,
            amount: reward,
        });
    }

    public entry fun stop_reward<StakeToken, RewardToken>(
        admin: &signer,
    ) acquires StakeOwnerCap, PoolInfo, Events {
        let admin_address = signer::address_of(admin);
        let cap = borrow_global<StakeOwnerCap>(@staking);
        assert!(admin_address == cap.admin, ERROR_ONLY_ADMIN);

        let pool = borrow_global_mut<PoolInfo<StakeToken, RewardToken>>(@staking);
        let now = timestamp::now_milliseconds();
        pool.end_timestamp = now;

        let events = borrow_global_mut<Events>(@staking);
        event::emit_event(&mut events.stop_reward_events, StopRewardEvent { timestamp: now });
    }

    public entry fun update_pool_limit_per_user<StakeToken, RewardToken>(
        admin: &signer,
        seconds_for_user_limit: bool,
        pool_limit_per_user: u64,
    ) acquires StakeOwnerCap, PoolInfo, Events {
        let admin_address = signer::address_of(admin);
        let cap = borrow_global<StakeOwnerCap>(@staking);
        assert!(admin_address == cap.admin, ERROR_ONLY_ADMIN);

        let pool = borrow_global_mut<PoolInfo<StakeToken, RewardToken>>(@staking);
        let now = timestamp::now_milliseconds();
        assert!((pool.seconds_for_user_limit > 0) && (now < (pool.start_timestamp + pool.seconds_for_user_limit)), ERROR_NO_LIMIT_SET);

        if (seconds_for_user_limit) {
            assert!(pool_limit_per_user > pool.pool_limit_per_user, ERROR_LIMIT_MUST_BE_HIGHER);
            pool.pool_limit_per_user = pool_limit_per_user;
        } else {
            pool.seconds_for_user_limit = 0;
            pool.pool_limit_per_user = 0;
        };

        let events = borrow_global_mut<Events>(@staking);
        event::emit_event(&mut events.new_pool_limit_events, NewPoolLimitEvent { pool_limit_per_user: pool.pool_limit_per_user });
    }

    public entry fun update_reward_per_second<StakeToken, RewardToken>(
        admin: &signer,
        reward_per_second: u64,
    ) acquires StakeOwnerCap, PoolInfo, Events {
        let admin_address = signer::address_of(admin);
        let cap = borrow_global<StakeOwnerCap>(@staking);
        assert!(admin_address == cap.admin, ERROR_ONLY_ADMIN);

        let pool = borrow_global_mut<PoolInfo<StakeToken, RewardToken>>(@staking);
        let now = timestamp::now_milliseconds();
        assert!(now < pool.start_timestamp, ERROR_POOL_STARTED);
        pool.reward_per_second = reward_per_second;

        let events = borrow_global_mut<Events>(@staking);
        event::emit_event(&mut events.new_reward_per_second_events, NewRewardPerSecondEvent { reward_per_second });
    }

    public entry fun update_start_and_end_timestamp<StakeToken, RewardToken>(
        admin: &signer,
        start_timestamp: u64,
        end_timestamp: u64,
    ) acquires StakeOwnerCap, PoolInfo, Events {
        let admin_address = signer::address_of(admin);
        let cap = borrow_global<StakeOwnerCap>(@staking);
        assert!(admin_address == cap.admin, ERROR_ONLY_ADMIN);

        let pool = borrow_global_mut<PoolInfo<StakeToken, RewardToken>>(@staking);
        let now = timestamp::now_milliseconds();
        assert!(now < pool.start_timestamp, ERROR_POOL_STARTED);
        assert!(start_timestamp < end_timestamp, ERROR_END_TIME_EARLIER_THAN_START_TIME);
        assert!(now < start_timestamp, ERROR_PASS_START_TIME);

        pool.start_timestamp = start_timestamp;
        pool.end_timestamp = end_timestamp;
        pool.last_reward_timestamp = start_timestamp;

        let events = borrow_global_mut<Events>(@staking);
        event::emit_event(&mut events.new_start_and_end_timestamp_events, NewStartAndEndTimestampEvent {
            start_timestamp,
            end_timestamp,
        });
    }

    public fun get_pool_info<StakeToken, RewardToken>(): (u64, u64, u64, u64, u64, u64, u64) acquires PoolInfo {
        let pool = borrow_global<PoolInfo<StakeToken, RewardToken>>(@staking);
        (
            pool.total_staked_token,
            pool.total_reward_token,
            pool.reward_per_second,
            pool.start_timestamp,
            pool.end_timestamp,
            pool.seconds_for_user_limit,
            pool.pool_limit_per_user,
        )
    }

    public fun get_user_stake_amount<StakeToken, RewardToken>(user: address): u64 acquires UserInfo {
        if (!exists<UserInfo<StakeToken, RewardToken>>(user)) {
            return 0
        };
        let user_info = borrow_global<UserInfo<StakeToken, RewardToken>>(user);
        user_info.amount
    }

    public fun get_pending_reward<StakeToken, RewardToken>(user: address): u64 acquires PoolInfo, UserInfo {
        if (!exists<UserInfo<StakeToken, RewardToken>>(user)) {
            return 0
        };

        let pool = borrow_global<PoolInfo<StakeToken, RewardToken>>(@staking);
        let user_info = borrow_global<UserInfo<StakeToken, RewardToken>>(user);
        let now = timestamp::now_milliseconds();

        let acc_token_per_share = if (pool.total_staked_token == 0 || now < pool.last_reward_timestamp) {
            pool.acc_token_per_share
        } else {
            cal_acc_token_per_share(
                pool.acc_token_per_share,
                pool.total_staked_token,
                pool.end_timestamp,
                pool.reward_per_second,
                pool.precision_factor,
                pool.last_reward_timestamp,
                now
            )
        };
        cal_pending_reward(user_info.amount, user_info.reward_debt, acc_token_per_share, pool.precision_factor)
    }

    // Helper functions
    fun update_pool<StakeToken, RewardToken>(pool: &mut PoolInfo<StakeToken, RewardToken>, now: u64) {
        if (now <= pool.last_reward_timestamp) return;

        if (pool.total_staked_token == 0) {
            pool.last_reward_timestamp = now;
            return
        };

        let new_acc_token_per_share = cal_acc_token_per_share(
            pool.acc_token_per_share,
            pool.total_staked_token,
            pool.end_timestamp,
            pool.reward_per_second,
            pool.precision_factor,
            pool.last_reward_timestamp,
            now
        );

        if (pool.acc_token_per_share == new_acc_token_per_share) return;
        pool.acc_token_per_share = new_acc_token_per_share;
        pool.last_reward_timestamp = now;
    }

    fun cal_acc_token_per_share(
        last_acc_token_per_share: u128, 
        total_staked_token: u64, 
        end_timestamp: u64, 
        reward_per_second: u64, 
        precision_factor: u128, 
        last_reward_timestamp: u64, 
        now: u64
    ): u128 {
        let multiplier = get_multiplier(last_reward_timestamp, now, end_timestamp);
        let reward = (reward_per_second as u128) * (multiplier as u128);
        if (multiplier == 0) return last_acc_token_per_share;
        last_acc_token_per_share + ((reward * precision_factor) / (total_staked_token as u128))
    }

    fun cal_pending_reward(amount: u64, reward_debt: u128, acc_token_per_share: u128, precision_factor: u128): u64 {
        (((amount as u128) * acc_token_per_share / precision_factor) - reward_debt) as u64
    }

    fun reward_debt(amount: u64, acc_token_per_share: u128, precision_factor: u128): u128 {
        (amount as u128) * acc_token_per_share / precision_factor
    }

    fun get_multiplier(from_timestamp: u64, to_timestamp: u64, end_timestamp: u64): u64 {
        if (to_timestamp <= end_timestamp) {
            to_timestamp - from_timestamp
        } else if (from_timestamp >= end_timestamp) {
            0
        } else {
            end_timestamp - from_timestamp
        }
    }
}   
