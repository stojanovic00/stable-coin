// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {ERC20Mock} from "../../test/mocks/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig helperConfig;

    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;

    address public USER = makeAddr("USER");
    address public LIQUIDATOR = makeAddr("LIQUIDATOR");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant DSC_MINT_AMOUNT = 50e18;
    uint256 public constant COVERED_AMOUNT_USD = 4000e18;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = helperConfig.activeNetworkConfig();

        //Mint tokens for the USER
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }
    //////////////////////////
    // Constructor Tests
    //////////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedsMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    //////////////////////////
    // Price Tests
    //////////////////////////

    function testGetUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000 USD/ETH = 30,000e18 USD
        uint256 expectedUsd = 30000e18;

        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);

        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;

        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(actualWeth, expectedWeth);
    }

    //////////////////////////
    // Deposit Collateral Tests
    //////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__TokenNotAllowed.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);

        uint256 expectedTotalDscMinted = 0;
        uint256 exptectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, exptectedDepositAmount);
    }
    //////////////////////////
    // Mint DSC Tests
    //////////////////////////

    function testMintDscRevertsBecauseOfBrokenHealthFactor() public {
        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, 0));

        dsce.mintDsc(DSC_MINT_AMOUNT);

        vm.stopPrank();
    }

    function testMintDscMintsProperly() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(DSC_MINT_AMOUNT);

        uint256 expectedTotalDscMinted = DSC_MINT_AMOUNT;
        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);

        assertEq(expectedTotalDscMinted, totalDscMinted);

        vm.stopPrank();
    }

    ////////////////////////////////////////
    // Deposit/Redeem Collateral and Mint DSC Tests
    ////////////////////////////////////////
    function testDepositCollateralAndMintDsc() public {
        vm.startPrank(USER);

        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, DSC_MINT_AMOUNT);

        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 collateralAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(AMOUNT_COLLATERAL, collateralAmount);
        assertEq(DSC_MINT_AMOUNT, totalDscMinted);

        vm.stopPrank();
    }

    //////////////////////////
    // Health factor Tests
    //////////////////////////

    function testHealthFactorReturnsMaxIntegerWhenNoDscMinted() public view {
        uint256 healthFactor = dsce.getHealthFactor(USER);
        assertEq(healthFactor, type(uint256).max);
    }

    /**
     * @notice  Helper function for debugging tests
     */
    function _printUserInfo(address user) internal view {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(user);
        console.log("totalDscMinted:", totalDscMinted);
        uint256 collateralAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        console.log("Collateral amount:", collateralAmount);
        console.log("Collateral in USD:", collateralValueInUsd);
    }

    function testHealthFactorCalculatesCorrectly() public depositedCollateral {
        //Deposited 10 ETH so 20 000 in USD
        // Minted 5 DSC so 5 USD
        // Adjusted Collateral = 20 000 * 50 / 100 = 10 000
        // 10 000 * precision / 5 = 2000e18  we multiply with precision because all zeros counter each other during division
        vm.startPrank(USER);
        dsce.mintDsc(AMOUNT_COLLATERAL / 2);

        uint256 expectedHealthFactor = 2000e18;
        uint256 healthFactor = dsce.getHealthFactor(USER);

        assertEq(healthFactor, expectedHealthFactor);
        vm.stopPrank();
    }
    //////////////////////////
    //Burning DSC factor Tests
    //////////////////////////

    function testBurnDscSuccess() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(100e18);

        dsc.approve(address(dsce), 50e18);
        dsce.burnDsc(50e18);

        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);

        assertEq(totalDscMinted, 50e18);
        vm.stopPrank();
    }

    //////////////////////////
    //Redeem Collateral Tests
    //////////////////////////
    function testRedeemCollateralSuccess() public depositedCollateral {
        vm.startPrank(USER);
        vm.stopPrank();

        vm.prank(USER);
        uint256 REDEEMED_AMOUNT = 3 ether;
        dsce.redeemCollateral(weth, REDEEMED_AMOUNT);
        (, uint256 collateralInUsd) = dsce.getAccountInformation(USER);
        uint256 collateralAmount = dsce.getTokenAmountFromUsd(weth, collateralInUsd);

        assertEq(collateralAmount, AMOUNT_COLLATERAL - REDEEMED_AMOUNT);
    }

    //////////////////////////
    //Liquidate Tests
    //////////////////////////
}
