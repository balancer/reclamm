// // SPDX-License-Identifier: GPL-3.0-or-later

// pragma solidity ^0.8.24;

// import "forge-std/Test.sol";
// import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
// import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";

// import { IRateProvider } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
// import { Rounding } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

// import { CastingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/CastingHelpers.sol";
// import { ERC20TestToken } from "@balancer-labs/v3-solidity-utils/contracts/test/ERC20TestToken.sol";
// import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/test/ArrayHelpers.sol";
// import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
// import {
//     E2eSwapRateProviderTest,
//     PoolFactoryMock
// } from "@balancer-labs/v3-vault/test/foundry/E2eSwapRateProvider.t.sol";

// import { ReClammPool } from "../../contracts/ReClammPool.sol";
// import { E2eSwapFuzzPoolParamsHelper } from "./utils/E2eSwapFuzzPoolParamsHelper.sol";

// contract E2eSwapReClammRateProvider is E2eSwapFuzzPoolParamsHelper, E2eSwapRateProviderTest {
//     using ArrayHelpers for *;
//     using FixedPoint for uint256;
//     using CastingHelpers for address[];

//     function setUp() public override {
//         super.setUp();

//         authorizer.grantRole(ReClammPool(address(pool)).getActionId(ReClammPool.setPriceRatioState.selector), alice);
//     }

//     function setUpVariables() internal override {
//         sender = lp;
//         poolCreator = lp;
//     }

//     function createPoolFactory() internal override returns (address) {
//         return address(deployReClammPoolFactoryWithDefaultParams(vault));
//     }

//     function _createPool(
//         address[] memory tokens,
//         string memory label
//     ) internal virtual override returns (address newPool, bytes memory poolArgs) {
//         IRateProvider[] memory rateProviders = new IRateProvider[](2);
//         rateProviders[tokenAIdx] = IRateProvider(address(rateProviderTokenA));
//         rateProviders[tokenBIdx] = IRateProvider(address(rateProviderTokenB));

//         (newPool, poolArgs) = createReClammPool(tokens, rateProviders, label, vault, lp);
//     }

//     function fuzzPoolParams(uint256[POOL_SPECIFIC_PARAMS_SIZE] memory params) internal override {
//         _fuzzPoolParams(params, ReClammPool(pool), router, alice);
//     }
// }
