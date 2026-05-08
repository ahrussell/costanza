// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IPoolStateReader.sol";

/// @notice Minimal interface for the bits of V4 PoolManager we need.
interface IPoolManagerExtsload {
    function extsload(bytes32 slot) external view returns (bytes32);
}

/// @title V4PoolStateReader
/// @notice Production implementation of `IPoolStateReader` for Uniswap V4
///         pools on Base. Reads the PoolManager's storage directly via
///         `extsload`, decoding the canonical V4 Pool.State layout.
///
/// @dev Storage layout (from `@uniswap/v4-core/PoolManager.sol`):
///        mapping(PoolId id => Pool.State) internal _pools;  // slot 6
///
///      For a given `poolId`:
///        baseSlot = keccak256(abi.encode(poolId, POOLS_SLOT))
///
///      `Pool.State` fields:
///        slot 0:    Slot0 packed (sqrtPriceX96, tick, protocolFee, lpFee)
///        slot 1:    feeGrowthGlobal0X128
///        slot 2:    feeGrowthGlobal1X128
///        slot 3:    liquidity (uint128 in low bits)
///        ... (mappings for ticks, tickBitmap, positions follow)
///
///      Slot0 packing:
///        bits   0-159 : sqrtPriceX96 (uint160)
///        bits 160-183 : tick (int24)
///        bits 184-207 : protocolFee (uint24)
///        bits 208-231 : lpFee (uint24)
///
/// @dev Stateless and trustless — caller passes the PoolId. One reader
///      contract serves any pool on the same PoolManager.
contract V4PoolStateReader is IPoolStateReader {
    /// @notice Storage slot of the `_pools` mapping in PoolManager.
    ///         Verified against the canonical v4-core deployment;
    ///         must be confirmed against Base mainnet PoolManager
    ///         bytecode before deploy if it ever upgrades.
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));

    /// @notice Offset (in slots) of `liquidity` within Pool.State,
    ///         after the three preceding 32-byte fields (slot0,
    ///         feeGrowthGlobal0, feeGrowthGlobal1).
    uint256 internal constant LIQUIDITY_OFFSET = 3;

    /// @notice The Uniswap V4 PoolManager singleton on Base.
    ///         (Canonical: 0x498581ff718922c3f8e6a244956af099b2652b2b.)
    IPoolManagerExtsload public immutable poolManager;

    constructor(address _poolManager) {
        poolManager = IPoolManagerExtsload(_poolManager);
    }

    function getSpotSqrtPriceX96(bytes32 poolId)
        external
        view
        override
        returns (uint160)
    {
        bytes32 slot0 = poolManager.extsload(_poolStateSlot(poolId));
        // Low 160 bits of slot0 are sqrtPriceX96.
        return uint160(uint256(slot0));
    }

    function getActiveLiquidity(bytes32 poolId)
        external
        view
        override
        returns (uint128)
    {
        bytes32 base = _poolStateSlot(poolId);
        bytes32 liquiditySlot = bytes32(uint256(base) + LIQUIDITY_OFFSET);
        bytes32 raw = poolManager.extsload(liquiditySlot);
        // `liquidity` is stored as uint128 in the low bits of its slot.
        return uint128(uint256(raw));
    }

    /// @dev Compute the storage slot of `Pool.State` for a given poolId.
    function _poolStateSlot(bytes32 poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(poolId, POOLS_SLOT));
    }
}
