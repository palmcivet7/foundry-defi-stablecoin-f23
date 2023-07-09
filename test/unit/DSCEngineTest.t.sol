// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "@chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth,,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    ////////////////////////////////
    ////// Constructor Tests //////
    //////////////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function testConstructorStoresPriceFeedsAndDsc() public {
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            assertEq(dsce.getPriceFeedForToken(tokenAddresses[i]), priceFeedAddresses[i]);
            assertEq(dsce.getCollateralTokenAtIndex(i), tokenAddresses[i]);
        }
        assertEq(address(dsce.getDscContract()), address(dsc));
    }

    //////////////////////////
    ////// Price Tests //////
    ////////////////////////

    function testGetUsdValue() public {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000/ETH = 30,000e18
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        // $2000 / ETH, $100
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    //////////////////////////////////////
    ////// depositCollateral Tests //////
    ////////////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
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
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }

    /////////////////////////
    //// mintDsc Tests /////
    ///////////////////////

    function testRevertsIfMintAmountZero() public {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositedCollateral {
        uint256 mintAmount = AMOUNT_COLLATERAL / 2;
        vm.startPrank(USER);
        dsce.mintDsc(mintAmount);
        (uint256 totalDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(totalDscMinted, mintAmount);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (amountCollateral * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateral(weth, amountCollateral);

        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(amountToMint, dsce.getUsdValue(weth, amountCollateral));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
    }

    modifier depositedCollateralAndMintedDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), amountCollateral);
        dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
        vm.stopPrank();
        _;
    }

    ///////////////////////////////
    ////// burnDsc() Tests ///////
    //////////////////////////////

    function testCanBurnDsc() public depositedCollateral {
        uint256 mintAmount = AMOUNT_COLLATERAL / 2;
        vm.startPrank(USER);
        dsce.mintDsc(mintAmount);
        dsc.approve(address(dsce), mintAmount); // approve the DSCEngine to burn the minted DSC
        // Burn the DSC
        uint256 dscToBurn = 1 ether; // 1 DSC
        dsce.burnDsc(dscToBurn);
        // Check the balance
        uint256 remainingDsc = dsc.balanceOf(USER);
        assertEq(remainingDsc, mintAmount - dscToBurn);
        vm.stopPrank();
    }

    function testRevertsIfBurnZero() public depositedCollateral {
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    // function testRevertsIfBurnMoreThanBalance() public depositedCollateral {
    //     // Mint some DSC to burn later
    //     uint256 dscToMint = 5 * 1 ether; // 5 DSC
    //     dsce.mintDsc(dscToMint);
    //     // Approve the DSCEngine to burn DSC on behalf of the user
    //     dsc.approve(address(dsce), dscToMint);

    //     // Attempt to burn more DSC than the user's balance
    //     uint256 dscToBurn = dscToMint + 1 ether; // 1 DSC more than the balance

    //     vm.startPrank(USER);
    //     vm.expectRevert(DecentralizedStableCoin.DecentralizedStableCoin__BurnAmountExceedsBalance.selector);
    //     dsce.burnDsc(dscToBurn);
    //     vm.stopPrank();
    // }

    // function testBalanceDecreasesAfterBurn() public depositedCollateral {
    //     // Mint and then burn some DSC
    //     uint256 dscToMintAndBurn = 1 ether;
    //     dsce.mintDsc(dscToMintAndBurn);
    //     dsce.burnDsc(dscToMintAndBurn);
    //     // Check the balance
    //     uint256 remainingDsc = dsc.balanceOf(USER);
    //     assertEq(remainingDsc, 0);
    // }

    /////////////////////////////////////
    ////// redeemCollateral Tests //////
    ///////////////////////////////////

    // function test_balanceUpdatesAfterRedeem() public {
    //     // Log initial balances
    //     uint256 initialBalanceUser = token.balanceOf(user);
    //     uint256 initialBalanceReceiver = token.balanceOf(receiver);

    //     // Call _redeemCollateral (you may need to adapt this if _redeemCollateral is private)
    //     dsce._redeemCollateral(user, receiver, address(token), amount);

    //     // Check final balances
    //     uint256 finalBalanceUser = token.balanceOf(user);
    //     uint256 finalBalanceReceiver = token.balanceOf(receiver);

    //     assertEq(finalBalanceUser, initialBalanceUser - amount, "Invalid final balance for the user");
    //     assertEq(finalBalanceReceiver, initialBalanceReceiver + amount, "Invalid final balance for the receiver");
    // }

    ///////////////////////////////////////////
    ////// redeemCollateralForDsc Tests //////
    /////////////////////////////////////////

    // function testCanRedeemCollateralForDsc() public depositedCollateral {
    //     // Mint some DSC
    //     uint256 dscToMint = 1 ether;
    //     console.log("************************************", dscToMint);
    //     dsce.mintDsc(dscToMint);
    //     // Redeem the DSC for collateral
    //     uint256 dscToRedeem = 1 ether;
    //     dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, dscToRedeem);
    //     // Check the balance
    //     uint256 remainingDsc = dsc.balanceOf(USER);
    //     // console.log("*************THE REMAININGDSC = ", remainingDsc);
    //     assertEq(remainingDsc, 0);
    // }

    // function testRevertsIfRedeemMoreThanDscBalance() public depositedCollateral {
    //     // Mint some DSC
    //     uint256 dscToMint = 1 ether;
    //     dsce.mintDsc(dscToMint);
    //     // Attempt to redeem more DSC than the user's balance
    //     uint256 dscToRedeem = 2 ether;
    //     vm.startPrank(USER);
    //     vm.expectRevert(DSCEngine.DSCEngine__BreaksHealthFactor.selector);
    //     dsce.redeemCollateralForDsc(dscToRedeem);
    //     vm.stopPrank();
    // }

    ////////////////////////////////////////////////
    ////// depositCollateralAndMintDsc Tests //////
    //////////////////////////////////////////////

    function testCanDepositCollateralAndMintDsc() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, (AMOUNT_COLLATERAL / 2));
        uint256 remainingDsc = dsc.balanceOf(USER);
        assertEq(remainingDsc, AMOUNT_COLLATERAL / 2);
        vm.stopPrank();
    }

    //////////////////////////////
    ////// liquidate Tests //////
    ////////////////////////////

    function testRevertsLiquidateIfHealthFactorOk() public {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
        dsc.approve(address(dsce), amountToMint);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);
        dsce.liquidate(weth, USER, amountToMint);
        vm.stopPrank();
    }

    ///////////////////////////
    ////// getter Tests //////
    /////////////////////////

    function testGetPriceFeedForToken() public {
        vm.startPrank(USER);
        address fetchedPriceFeedAddress = dsce.getPriceFeedForToken(weth);
        assertEq(fetchedPriceFeedAddress, ethUsdPriceFeed);
        vm.stopPrank();
    }

    function testGetCollateralTokenAtIndex() public {
        vm.startPrank(USER);
        uint256 indexToTest = 0;
        address expectedCollateralTokenAddress = weth;
        address fetchedCollateralTokenAddress = dsce.getCollateralTokenAtIndex(indexToTest);
        assertEq(fetchedCollateralTokenAddress, expectedCollateralTokenAddress);
        vm.stopPrank();
    }

    function testGetCollateralTokensLength() public {
        // Initialize the tokenAddresses array with the weth and wbtc addresses
        tokenAddresses.push(weth);
        tokenAddresses.push(wbtc);

        // Initialize the priceFeedAddresses array with the ethUsdPriceFeed and btcUsdPriceFeed addresses
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.startPrank(USER);
        uint256 expectedLength = tokenAddresses.length;
        uint256 fetchedLength = dsce.getCollateralTokensLength();
        assertEq(fetchedLength, expectedLength);
        vm.stopPrank();
    }

    function testGetDscContract() public {
        vm.startPrank(USER);
        DecentralizedStableCoin expectedDscContract = dsc;
        DecentralizedStableCoin fetchedDscContract = dsce.getDscContract();
        assertEq(address(fetchedDscContract), address(expectedDscContract));
        vm.stopPrank();
    }
}
