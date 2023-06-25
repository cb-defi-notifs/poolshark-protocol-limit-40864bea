// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.13;

import '../interfaces/ILimitPoolStructs.sol';
import '../interfaces/modules/curves/ICurveMath.sol';
import './EpochMap.sol';
import './TickMap.sol';
import './utils/String.sol';
import './utils/SafeCast.sol';
import 'hardhat/console.sol';

library Claims {
    /////////// DEBUG FLAGS ///////////
    bool constant debugDeltas = true;

    using SafeCast for uint256;

    function validate(
        mapping(address => mapping(int24 => mapping(int24 => ILimitPoolStructs.Position)))
            storage positions,
        ILimitPoolStructs.TickMap storage tickMap,
        ILimitPoolStructs.GlobalState memory state,
        ILimitPoolStructs.PoolState memory pool,
        ILimitPoolStructs.UpdateParams memory params,
        ILimitPoolStructs.UpdatePositionCache memory cache,
        ILimitPoolStructs.Immutables memory constants
    ) external view returns (
        ILimitPoolStructs.UpdatePositionCache memory
    ) {
        // validate position liquidity
        if (params.amount > cache.position.liquidity) require (false, 'NotEnoughPositionLiquidity()');
        if (cache.position.liquidity == 0) {
            cache.earlyReturn = true;
            return cache;
        }
        // if the position has not been crossed into at all
        else if (params.zeroForOne ? params.claim == params.lower 
                                        && EpochMap.get(params.lower, tickMap, constants) <= cache.position.epochLast
                                     : params.claim == params.upper 
                                        && EpochMap.get(params.upper, tickMap, constants) <= cache.position.epochLast
        ) {
            cache.earlyReturn = true;
            return cache;
        }
        // early return if no update and amount burned is 0
        if (params.amount == 0 && cache.position.claimPriceLast == pool.price) {
                cache.earlyReturn = true;
                return cache;
        } 
        
        // claim tick sanity checks
        else if (
            // claim tick is on a prior tick
            cache.position.claimPriceLast > 0 &&
            (params.zeroForOne
                    ? cache.position.claimPriceLast > cache.priceClaim
                    : cache.position.claimPriceLast < cache.priceClaim
            )
        ) require (false, 'InvalidClaimTick()'); /// @dev - wrong claim tick
        if (params.claim < params.lower || params.claim > params.upper) require (false, 'InvalidClaimTick()');

        uint32 claimTickEpoch;
        if (params.claim != pool.tickAtPrice)
            claimTickEpoch = EpochMap.get(params.claim, tickMap, constants);
        else if (params.lower <= pool.tickAtPrice && pool.tickAtPrice <= params.upper) {
            console.log('tick at price check');
            console.logInt(pool.tickAtPrice);
            cache.priceClaim = pool.price;
            claimTickEpoch = pool.swapEpoch;
        }

        console.log('claim tick epoch', claimTickEpoch);
        console.logInt(params.claim);

        // validate claim tick
        if (params.claim == (params.zeroForOne ? params.upper : params.lower)) {
             if (claimTickEpoch <= cache.position.epochLast)
                require (false, 'WrongTickClaimedAt()');
        } else {
            // zero fill or partial fill
            uint32 claimTickNextAccumEpoch = params.zeroForOne
                ? EpochMap.get(TickMap.next(tickMap, params.claim, constants.tickSpacing), tickMap, constants)
                : EpochMap.get(TickMap.previous(tickMap, params.claim, constants.tickSpacing), tickMap, constants);
            ///@dev - next swapEpoch should not be greater
            if (claimTickNextAccumEpoch > cache.position.epochLast) {
                require (false, 'WrongTickClaimedAt()');
            }
        }
        if (params.claim != params.upper && params.claim != params.lower) {
            // check epochLast on claim tick
            if (claimTickEpoch <= cache.position.epochLast)
                require (false, 'WrongTickClaimedAt()');
            // prevent position overwriting at claim tick
            if (params.zeroForOne) {
                if (positions[params.owner][params.lower][params.claim].liquidity > 0) {
                    require (false, string.concat('UpdatePositionFirstAt(', String.from(params.lower), ', ', String.from(params.claim), ')'));
                }
            } else {
                if (positions[params.owner][params.claim][params.upper].liquidity > 0) {
                    require (false, string.concat('UpdatePositionFirstAt(', String.from(params.lower), ', ', String.from(params.claim), ')'));
                }
            }
            /// @dev - user cannot add liquidity if auction is active; checked for in Positions.validate()
        }
        return cache;
    }

    function getDeltas(
        ILimitPoolStructs.UpdatePositionCache memory cache,
        ILimitPoolStructs.UpdateParams memory params
    ) external pure returns (
        ILimitPoolStructs.UpdatePositionCache memory
    ) {
        cache.position.amountIn += uint128(params.zeroForOne ? ConstantProduct.getDy(cache.position.liquidity, cache.position.claimPriceLast, cache.priceClaim, false)
                                                             : ConstantProduct.getDx(cache.position.liquidity, cache.priceClaim, cache.position.claimPriceLast, false));
        if (params.claim != (params.zeroForOne ? params.upper : params.lower)) {
            cache.position.amountOut += uint128(params.zeroForOne ? ConstantProduct.getDx(cache.position.liquidity, cache.priceClaim, cache.priceUpper, false)
                                                                  : ConstantProduct.getDy(cache.position.liquidity, cache.priceLower, cache.priceClaim, false));
        }
        return cache;
    }
}