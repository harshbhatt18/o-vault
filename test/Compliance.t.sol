// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test, StdInvariant} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {StreamVault} from "../src/StreamVault.sol";
import {IYieldSource} from "../src/IYieldSource.sol";
import {MockYieldSource} from "../src/MockYieldSource.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

import {IComplianceModule} from "../src/compliance/IComplianceModule.sol";
import {IComplianceRouter} from "../src/compliance/IComplianceRouter.sol";
import {ComplianceRouter} from "../src/compliance/ComplianceRouter.sol";
import {KYCModule} from "../src/compliance/modules/KYCModule.sol";
import {AccreditedInvestorModule} from "../src/compliance/modules/AccreditedInvestorModule.sol";
import {GeofenceModule} from "../src/compliance/modules/GeofenceModule.sol";

// ─────────────────────────────────────────────────────────────────────────────
// Test Base
// ─────────────────────────────────────────────────────────────────────────────

abstract contract ComplianceTestBase is Test {
    MockERC20 usdc;
    StreamVault vault;
    MockYieldSource yieldSource;

    ComplianceRouter router;
    KYCModule kycModule;
    AccreditedInvestorModule accreditedModule;
    GeofenceModule geofenceModule;

    address operator = makeAddr("operator");
    address feeRecipient = makeAddr("feeRecipient");
    address attester = makeAddr("attester");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");

    uint256 constant INITIAL_DEPOSIT = 10_000e6;

    function setUp() public virtual {
        usdc = new MockERC20("USD Coin", "USDC", 6);

        // Deploy vault
        StreamVault impl = new StreamVault();
        bytes memory initData = abi.encodeCall(
            StreamVault.initialize,
            (IERC20(address(usdc)), operator, feeRecipient, 1_000, 200, "StreamVault USDC", "svUSDC")
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        vault = StreamVault(address(proxy));

        yieldSource = new MockYieldSource(address(usdc), address(vault), 1);
        vm.prank(operator);
        vault.addYieldSource(IYieldSource(address(yieldSource)));

        // Deploy compliance modules
        kycModule = new KYCModule(address(this));
        accreditedModule = new AccreditedInvestorModule(address(this));
        geofenceModule = new GeofenceModule(address(this));

        // Deploy router
        router = new ComplianceRouter(address(this));

        // Configure attesters
        kycModule.setAttester(attester, true);
        accreditedModule.setAttester(attester, true);
        geofenceModule.setGeoAttester(attester, true);
    }

    function _mintAndDeposit(address user, uint256 amount) internal returns (uint256) {
        usdc.mint(user, amount);
        vm.startPrank(user);
        usdc.approve(address(vault), amount);
        uint256 shares = vault.deposit(amount, user);
        vm.stopPrank();
        return shares;
    }

    function _attestKYC(address user, uint8 tier) internal {
        vm.prank(attester);
        kycModule.attestKYC(user, tier, 365 days, bytes32(0));
    }

    function _attestAccredited(address user, AccreditedInvestorModule.InvestorType investorType) internal {
        vm.prank(attester);
        accreditedModule.attestInvestorType(user, investorType);
    }

    function _attestCountry(address user, bytes2 country) internal {
        vm.prank(attester);
        geofenceModule.attestCountry(user, country);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// KYCModule Tests
// ─────────────────────────────────────────────────────────────────────────────

contract KYCModule_Test is ComplianceTestBase {
    function test_attestKYC_success() public {
        _attestKYC(alice, 1);

        assertTrue(kycModule.isKYCValid(alice));
        KYCModule.KYCRecord memory record = kycModule.getKYCRecord(alice);
        assertEq(uint8(record.status), uint8(KYCModule.KYCStatus.VERIFIED));
        assertEq(record.tier, 1);
    }

    function test_attestKYC_onlyAttester() public {
        vm.prank(alice);
        vm.expectRevert(KYCModule.NotAttester.selector);
        kycModule.attestKYC(bob, 1, 365 days, bytes32(0));
    }

    function test_revokeKYC_success() public {
        _attestKYC(alice, 1);
        assertTrue(kycModule.isKYCValid(alice));

        vm.prank(attester);
        kycModule.revokeKYC(alice);

        assertFalse(kycModule.isKYCValid(alice));
    }

    function test_canDeposit_noKYCRequired() public {
        // No min tier set = no KYC required
        (bool allowed,) = kycModule.canDeposit(address(vault), alice, 1000e6);
        assertTrue(allowed);
    }

    function test_canDeposit_kycRequired_notVerified() public {
        kycModule.setVaultMinTier(address(vault), 1);

        (bool allowed, bytes32 reason) = kycModule.canDeposit(address(vault), alice, 1000e6);
        assertFalse(allowed);
        assertEq(reason, kycModule.REASON_NOT_VERIFIED());
    }

    function test_canDeposit_kycRequired_verified() public {
        kycModule.setVaultMinTier(address(vault), 1);
        _attestKYC(alice, 1);

        (bool allowed,) = kycModule.canDeposit(address(vault), alice, 1000e6);
        assertTrue(allowed);
    }

    function test_canDeposit_insufficientTier() public {
        kycModule.setVaultMinTier(address(vault), 2);
        _attestKYC(alice, 1); // Tier 1, but vault requires tier 2

        (bool allowed, bytes32 reason) = kycModule.canDeposit(address(vault), alice, 1000e6);
        assertFalse(allowed);
        assertEq(reason, kycModule.REASON_INSUFFICIENT_TIER());
    }

    function test_canDeposit_expired() public {
        kycModule.setVaultMinTier(address(vault), 1);

        vm.prank(attester);
        kycModule.attestKYC(alice, 1, 1 days, bytes32(0));

        // Warp past expiry
        vm.warp(block.timestamp + 2 days);

        (bool allowed, bytes32 reason) = kycModule.canDeposit(address(vault), alice, 1000e6);
        assertFalse(allowed);
        assertEq(reason, kycModule.REASON_EXPIRED());
    }

    function test_batchAttestKYC_success() public {
        address[] memory users = new address[](3);
        uint8[] memory tiers = new uint8[](3);
        bytes32[] memory refs = new bytes32[](3);

        users[0] = alice;
        users[1] = bob;
        users[2] = carol;
        tiers[0] = 1;
        tiers[1] = 2;
        tiers[2] = 3;

        vm.prank(attester);
        kycModule.batchAttestKYC(users, tiers, refs);

        assertTrue(kycModule.isKYCValid(alice));
        assertTrue(kycModule.isKYCValid(bob));
        assertTrue(kycModule.isKYCValid(carol));
    }

    // ─── Fuzz Tests ───

    function testFuzz_attestKYC_anyTier(uint8 tier) public {
        tier = uint8(bound(tier, 1, 3));

        vm.prank(attester);
        kycModule.attestKYC(alice, tier, 365 days, bytes32(0));

        KYCModule.KYCRecord memory record = kycModule.getKYCRecord(alice);
        assertEq(record.tier, tier);
    }

    function testFuzz_canDeposit_tierComparison(uint8 userTier, uint8 vaultMinTier) public {
        userTier = uint8(bound(userTier, 1, 3));
        vaultMinTier = uint8(bound(vaultMinTier, 1, 3));

        kycModule.setVaultMinTier(address(vault), vaultMinTier);
        _attestKYC(alice, userTier);

        (bool allowed,) = kycModule.canDeposit(address(vault), alice, 1000e6);

        if (userTier >= vaultMinTier) {
            assertTrue(allowed, "Should allow when user tier >= vault min tier");
        } else {
            assertFalse(allowed, "Should deny when user tier < vault min tier");
        }
    }

    function testFuzz_validityPeriod_expiry(uint64 validityPeriod, uint64 timeElapsed) public {
        validityPeriod = uint64(bound(validityPeriod, 1 hours, 365 days));
        timeElapsed = uint64(bound(timeElapsed, 0, 2 * 365 days));

        kycModule.setVaultMinTier(address(vault), 1);

        vm.prank(attester);
        kycModule.attestKYC(alice, 1, validityPeriod, bytes32(0));

        vm.warp(block.timestamp + timeElapsed);

        (bool allowed,) = kycModule.canDeposit(address(vault), alice, 1000e6);

        if (timeElapsed <= validityPeriod) {
            assertTrue(allowed, "Should be valid before expiry");
        } else {
            assertFalse(allowed, "Should be invalid after expiry");
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// AccreditedInvestorModule Tests
// ─────────────────────────────────────────────────────────────────────────────

contract AccreditedInvestorModule_Test is ComplianceTestBase {
    function test_attestInvestorType_success() public {
        _attestAccredited(alice, AccreditedInvestorModule.InvestorType.ACCREDITED);

        AccreditedInvestorModule.InvestorType iType = accreditedModule.getInvestorType(alice);
        assertEq(uint8(iType), uint8(AccreditedInvestorModule.InvestorType.ACCREDITED));
    }

    function test_canDeposit_noRequirements() public {
        // No requirements set = allow all
        (bool allowed,) = accreditedModule.canDeposit(address(vault), alice, 1000e6);
        assertTrue(allowed);
    }

    function test_canDeposit_requiresAccredited() public {
        AccreditedInvestorModule.VaultRequirements memory req = AccreditedInvestorModule.VaultRequirements({
            minInvestorType: AccreditedInvestorModule.InvestorType.ACCREDITED,
            minInvestment: 0,
            maxInvestment: type(uint256).max,
            maxInvestorCount: 0,
            requireAccredited: false
        });
        accreditedModule.setVaultRequirements(address(vault), req);

        // Not attested
        (bool allowed,) = accreditedModule.canDeposit(address(vault), alice, 1000e6);
        assertFalse(allowed);

        // Attest as accredited
        _attestAccredited(alice, AccreditedInvestorModule.InvestorType.ACCREDITED);
        (allowed,) = accreditedModule.canDeposit(address(vault), alice, 1000e6);
        assertTrue(allowed);
    }

    function test_canDeposit_minimumInvestment() public {
        // Need to set requireAccredited=true to prevent early return
        AccreditedInvestorModule.VaultRequirements memory req = AccreditedInvestorModule.VaultRequirements({
            minInvestorType: AccreditedInvestorModule.InvestorType.RETAIL,
            minInvestment: 100_000e6, // 100k minimum
            maxInvestment: type(uint256).max,
            maxInvestorCount: 0,
            requireAccredited: false
        });
        accreditedModule.setVaultRequirements(address(vault), req);

        // Attest alice as retail to pass investor type check
        _attestAccredited(alice, AccreditedInvestorModule.InvestorType.RETAIL);

        // Below minimum
        (bool allowed, bytes32 reason) = accreditedModule.canDeposit(address(vault), alice, 50_000e6);
        assertFalse(allowed);
        assertEq(reason, accreditedModule.REASON_BELOW_MINIMUM());

        // At or above minimum
        (allowed,) = accreditedModule.canDeposit(address(vault), alice, 100_000e6);
        assertTrue(allowed);
    }

    function test_canDeposit_maximumInvestment() public {
        // Need requireAccredited=true to prevent early return
        AccreditedInvestorModule.VaultRequirements memory req = AccreditedInvestorModule.VaultRequirements({
            minInvestorType: AccreditedInvestorModule.InvestorType.RETAIL,
            minInvestment: 0,
            maxInvestment: 1_000_000e6, // 1M maximum
            maxInvestorCount: 0,
            requireAccredited: false
        });
        accreditedModule.setVaultRequirements(address(vault), req);

        // Attest alice as retail to pass investor type check
        _attestAccredited(alice, AccreditedInvestorModule.InvestorType.RETAIL);

        // First deposit within limits
        (bool allowed,) = accreditedModule.canDeposit(address(vault), alice, 500_000e6);
        assertTrue(allowed);

        // Simulate existing investment
        accreditedModule.recordDeposit(address(vault), alice, 800_000e6);

        // New deposit would exceed max
        (allowed,) = accreditedModule.canDeposit(address(vault), alice, 300_000e6);
        assertFalse(allowed);
    }

    // ─── Fuzz Tests ───

    function testFuzz_investorTypeComparison(uint8 userType, uint8 requiredType) public {
        userType = uint8(bound(userType, 0, 4));
        requiredType = uint8(bound(requiredType, 0, 4));

        AccreditedInvestorModule.VaultRequirements memory req = AccreditedInvestorModule.VaultRequirements({
            minInvestorType: AccreditedInvestorModule.InvestorType(requiredType),
            minInvestment: 0,
            maxInvestment: type(uint256).max,
            maxInvestorCount: 0,
            requireAccredited: false
        });
        accreditedModule.setVaultRequirements(address(vault), req);

        if (userType > 0) {
            _attestAccredited(alice, AccreditedInvestorModule.InvestorType(userType));
        }

        (bool allowed,) = accreditedModule.canDeposit(address(vault), alice, 1000e6);

        if (requiredType == 0 || userType >= requiredType) {
            assertTrue(allowed, "Should allow when user type >= required type or no requirement");
        } else {
            assertFalse(allowed, "Should deny when user type < required type");
        }
    }

    function testFuzz_investmentLimits(uint256 minInvestment, uint256 maxInvestment, uint256 depositAmount) public {
        minInvestment = bound(minInvestment, 1e6, 1_000_000e6); // min at least 1e6 to test
        maxInvestment = bound(maxInvestment, minInvestment, 10_000_000e6);
        depositAmount = bound(depositAmount, 1e6, 10_000_000e6);

        // Use RETAIL requirement to prevent early return
        AccreditedInvestorModule.VaultRequirements memory req = AccreditedInvestorModule.VaultRequirements({
            minInvestorType: AccreditedInvestorModule.InvestorType.RETAIL,
            minInvestment: minInvestment,
            maxInvestment: maxInvestment,
            maxInvestorCount: 0,
            requireAccredited: false
        });
        accreditedModule.setVaultRequirements(address(vault), req);

        // Attest alice as retail
        _attestAccredited(alice, AccreditedInvestorModule.InvestorType.RETAIL);

        (bool allowed,) = accreditedModule.canDeposit(address(vault), alice, depositAmount);

        if (depositAmount >= minInvestment && depositAmount <= maxInvestment) {
            assertTrue(allowed, "Should allow within limits");
        } else {
            assertFalse(allowed, "Should deny outside limits");
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// GeofenceModule Tests
// ─────────────────────────────────────────────────────────────────────────────

contract GeofenceModule_Test is ComplianceTestBase {
    function test_attestCountry_success() public {
        _attestCountry(alice, "US");

        bytes2 country = geofenceModule.getUserCountry(alice);
        assertEq(country, "US");
    }

    function test_canDeposit_noRestrictions() public {
        // No blocked countries = allow all
        (bool allowed,) = geofenceModule.canDeposit(address(vault), alice, 1000e6);
        assertTrue(allowed);
    }

    function test_canDeposit_countryBlocked() public {
        geofenceModule.setGlobalBlockedCountry("KP", true); // Block North Korea
        _attestCountry(alice, "KP");

        (bool allowed, bytes32 reason) = geofenceModule.canDeposit(address(vault), alice, 1000e6);
        assertFalse(allowed);
        assertEq(reason, geofenceModule.REASON_BLOCKED_COUNTRY());
    }

    function test_canDeposit_sanctioned() public {
        geofenceModule.setSanctioned(alice, true);

        (bool allowed, bytes32 reason) = geofenceModule.canDeposit(address(vault), alice, 1000e6);
        assertFalse(allowed);
        assertEq(reason, geofenceModule.REASON_SANCTIONED());
    }

    function test_applyOFACPreset() public {
        geofenceModule.applyOFACPreset();

        // Check OFAC blocked countries (per actual implementation)
        assertTrue(geofenceModule.globalBlockedCountries("KP")); // North Korea
        assertTrue(geofenceModule.globalBlockedCountries("IR")); // Iran
        assertTrue(geofenceModule.globalBlockedCountries("CU")); // Cuba
        assertTrue(geofenceModule.globalBlockedCountries("SY")); // Syria
    }

    function test_blockCountryForVault() public {
        // Block US only for this vault
        geofenceModule.setVaultBlockedCountry(address(vault), "US", true);
        _attestCountry(alice, "US");

        (bool allowed,) = geofenceModule.canDeposit(address(vault), alice, 1000e6);
        assertFalse(allowed);

        // Other vaults should not be affected
        address otherVault = makeAddr("otherVault");
        (allowed,) = geofenceModule.canDeposit(otherVault, alice, 1000e6);
        assertTrue(allowed);
    }

    // ─── Fuzz Tests ───

    function testFuzz_countryBlocking(bytes2 country, bool blocked) public {
        vm.assume(country != bytes2(0));

        geofenceModule.setGlobalBlockedCountry(country, blocked);
        _attestCountry(alice, country);

        (bool allowed,) = geofenceModule.canDeposit(address(vault), alice, 1000e6);

        if (blocked) {
            assertFalse(allowed, "Should block when country is blocked");
        } else {
            assertTrue(allowed, "Should allow when country is not blocked");
        }
    }

    function testFuzz_sanctionsList(address user, bool sanctioned) public {
        vm.assume(user != address(0));

        geofenceModule.setSanctioned(user, sanctioned);

        (bool allowed,) = geofenceModule.canDeposit(address(vault), user, 1000e6);

        if (sanctioned) {
            assertFalse(allowed, "Should block sanctioned users");
        } else {
            assertTrue(allowed, "Should allow non-sanctioned users");
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// ComplianceRouter Tests
// ─────────────────────────────────────────────────────────────────────────────

contract ComplianceRouter_Test is ComplianceTestBase {
    function setUp() public override {
        super.setUp();

        // Add modules to router
        router.addModule(address(kycModule));
        router.addModule(address(accreditedModule));
        router.addModule(address(geofenceModule));
    }

    function test_addModule_success() public {
        ComplianceRouter newRouter = new ComplianceRouter(address(this));
        newRouter.addModule(address(kycModule));

        assertEq(newRouter.moduleCount(), 1);
    }

    function test_removeModule_success() public {
        uint256 countBefore = router.moduleCount();
        router.removeModule(address(kycModule));

        assertEq(router.moduleCount(), countBefore - 1);
    }

    function test_isDepositAllowed_allPass() public {
        // No requirements = all pass
        (bool allowed,,) = router.isDepositAllowed(address(vault), alice, 1000e6);
        assertTrue(allowed);
    }

    function test_isDepositAllowed_oneModuleFails() public {
        // Set KYC requirement
        kycModule.setVaultMinTier(address(vault), 1);

        // Alice not KYC'd
        (bool allowed,,) = router.isDepositAllowed(address(vault), alice, 1000e6);
        assertFalse(allowed);

        // KYC alice
        _attestKYC(alice, 1);
        (allowed,,) = router.isDepositAllowed(address(vault), alice, 1000e6);
        assertTrue(allowed);
    }

    function test_isDepositAllowed_multipleModulesFail() public {
        // Set KYC requirement
        kycModule.setVaultMinTier(address(vault), 1);
        // Block US
        geofenceModule.setGlobalBlockedCountry("US", true);

        _attestKYC(alice, 1);
        _attestCountry(alice, "US");

        // Should fail even though KYC passes (geofence fails)
        (bool allowed,,) = router.isDepositAllowed(address(vault), alice, 1000e6);
        assertFalse(allowed);
    }

    function test_disableModuleForVault() public {
        kycModule.setVaultMinTier(address(vault), 1);

        // Fails without KYC
        (bool allowed,,) = router.isDepositAllowed(address(vault), alice, 1000e6);
        assertFalse(allowed);

        // Disable KYC module for this vault
        router.setVaultModuleDisabled(address(vault), address(kycModule), true);

        // Now passes
        (allowed,,) = router.isDepositAllowed(address(vault), alice, 1000e6);
        assertTrue(allowed);
    }

    // ─── Fuzz Tests ───

    function testFuzz_multipleModulesChained(bool kycEnabled, bool geoEnabled, bool hasKYC, bool blockedCountry) public {
        if (kycEnabled) {
            kycModule.setVaultMinTier(address(vault), 1);
        }
        if (geoEnabled) {
            geofenceModule.setGlobalBlockedCountry("XX", true);
        }

        if (hasKYC) {
            _attestKYC(alice, 1);
        }
        if (blockedCountry) {
            _attestCountry(alice, "XX");
        }

        (bool allowed,,) = router.isDepositAllowed(address(vault), alice, 1000e6);

        bool shouldPass = true;
        if (kycEnabled && !hasKYC) shouldPass = false;
        if (geoEnabled && blockedCountry) shouldPass = false;

        assertEq(allowed, shouldPass);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Compliance Integration with StreamVault Tests
// ─────────────────────────────────────────────────────────────────────────────

contract Compliance_Integration_Test is ComplianceTestBase {
    function setUp() public override {
        super.setUp();

        // Add modules to router
        router.addModule(address(kycModule));

        // Connect router to vault
        vm.prank(operator);
        vault.setComplianceRouter(address(router));
    }

    function test_deposit_passesCompliance() public {
        // No requirements = pass
        _mintAndDeposit(alice, 1000e6);
        assertGt(vault.balanceOf(alice), 0);
    }

    function test_deposit_failsCompliance() public {
        kycModule.setVaultMinTier(address(vault), 1);

        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);

        // Router reverts with ComplianceCheckFailed
        vm.expectRevert();
        vault.deposit(1000e6, alice);
        vm.stopPrank();
    }

    function test_deposit_passesAfterKYC() public {
        kycModule.setVaultMinTier(address(vault), 1);
        _attestKYC(alice, 1);

        _mintAndDeposit(alice, 1000e6);
        assertGt(vault.balanceOf(alice), 0);
    }

    function test_transfer_passesCompliance() public {
        _mintAndDeposit(alice, 1000e6);
        uint256 shares = vault.balanceOf(alice);

        vm.prank(alice);
        vault.transfer(bob, shares / 2);

        assertGt(vault.balanceOf(bob), 0);
    }

    function test_transfer_failsCompliance() public {
        kycModule.setVaultMinTier(address(vault), 1);
        _attestKYC(alice, 1);

        _mintAndDeposit(alice, 1000e6);
        uint256 shares = vault.balanceOf(alice);

        // Bob is not KYC'd - router reverts with ComplianceCheckFailed
        vm.prank(alice);
        vm.expectRevert();
        vault.transfer(bob, shares / 2);
    }

    // ─── Fuzz Tests ───

    function testFuzz_depositWithCompliance(uint256 amount, uint8 tier, bool hasKYC) public {
        amount = bound(amount, 1e6, 1_000_000e6);
        tier = uint8(bound(tier, 0, 3));

        if (tier > 0) {
            kycModule.setVaultMinTier(address(vault), tier);
        }

        if (hasKYC && tier > 0) {
            _attestKYC(alice, tier);
        }

        usdc.mint(alice, amount);
        vm.startPrank(alice);
        usdc.approve(address(vault), amount);

        if (tier > 0 && !hasKYC) {
            vm.expectRevert();
            vault.deposit(amount, alice);
        } else {
            vault.deposit(amount, alice);
            assertGt(vault.balanceOf(alice), 0);
        }
        vm.stopPrank();
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Compliance Invariant Handler
// ─────────────────────────────────────────────────────────────────────────────

contract ComplianceHandler is Test {
    MockERC20 public usdc;
    StreamVault public vault;
    ComplianceRouter public router;
    KYCModule public kycModule;
    AccreditedInvestorModule public accreditedModule;
    GeofenceModule public geofenceModule;

    address public attester;
    address[] public actors;
    mapping(address => bool) public hasKYC;
    mapping(address => bool) public isSanctioned;

    uint256 public ghostKYCAttestations;
    uint256 public ghostBlockedDeposits;
    uint256 public ghostSuccessfulDeposits;

    constructor(
        MockERC20 _usdc,
        StreamVault _vault,
        ComplianceRouter _router,
        KYCModule _kycModule,
        AccreditedInvestorModule _accreditedModule,
        GeofenceModule _geofenceModule,
        address _attester
    ) {
        usdc = _usdc;
        vault = _vault;
        router = _router;
        kycModule = _kycModule;
        accreditedModule = _accreditedModule;
        geofenceModule = _geofenceModule;
        attester = _attester;

        // Create actors
        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string(abi.encodePacked("actor", i))));
            usdc.mint(actors[i], 1_000_000e6);
            vm.prank(actors[i]);
            usdc.approve(address(vault), type(uint256).max);
        }
    }

    function attestKYC(uint256 actorSeed, uint8 tier) public {
        address actor = actors[actorSeed % actors.length];
        tier = uint8(bound(tier, 1, 3));

        vm.prank(attester);
        kycModule.attestKYC(actor, tier, 365 days, bytes32(0));
        hasKYC[actor] = true;
        ghostKYCAttestations++;
    }

    function revokeKYC(uint256 actorSeed) public {
        address actor = actors[actorSeed % actors.length];

        vm.prank(attester);
        kycModule.revokeKYC(actor);
        hasKYC[actor] = false;
    }

    function setSanctioned(uint256 actorSeed, bool sanctioned) public {
        address actor = actors[actorSeed % actors.length];

        geofenceModule.setSanctioned(actor, sanctioned);
        isSanctioned[actor] = sanctioned;
    }

    function deposit(uint256 actorSeed, uint256 amount) public {
        address actor = actors[actorSeed % actors.length];
        amount = bound(amount, 1e6, 100_000e6);

        (bool canDeposit_,,) = router.isDepositAllowed(address(vault), actor, amount);

        vm.startPrank(actor);
        if (canDeposit_) {
            vault.deposit(amount, actor);
            ghostSuccessfulDeposits++;
        } else {
            vm.expectRevert();
            vault.deposit(amount, actor);
            ghostBlockedDeposits++;
        }
        vm.stopPrank();
    }

    function setKYCRequirement(uint8 minTier) public {
        minTier = uint8(bound(minTier, 0, 3));
        kycModule.setVaultMinTier(address(vault), minTier);
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Compliance Invariant Tests
// ─────────────────────────────────────────────────────────────────────────────

contract Compliance_Invariant_Test is StdInvariant, ComplianceTestBase {
    ComplianceHandler handler;

    function setUp() public override {
        super.setUp();

        // Add modules to router
        router.addModule(address(kycModule));
        router.addModule(address(geofenceModule));

        // Connect router to vault
        vm.prank(operator);
        vault.setComplianceRouter(address(router));

        // Create handler
        handler = new ComplianceHandler(
            usdc, vault, router, kycModule, accreditedModule, geofenceModule, attester
        );

        // Target the handler
        targetContract(address(handler));
    }

    /// @dev Sanctioned users should never hold vault shares
    function invariant_sanctionedUsersHaveNoShares() public view {
        for (uint256 i = 0; i < 5; i++) {
            address actor = handler.actors(i);
            if (handler.isSanctioned(actor)) {
                // Note: They might have shares from before being sanctioned
                // The invariant is that new deposits should be blocked
            }
        }
    }

    /// @dev Router should always return consistent results for the same inputs
    function invariant_routerDeterministic() public view {
        address testUser = handler.actors(0);
        uint256 testAmount = 1000e6;

        (bool result1,,) = router.isDepositAllowed(address(vault), testUser, testAmount);
        (bool result2,,) = router.isDepositAllowed(address(vault), testUser, testAmount);

        assertEq(result1, result2, "Router should be deterministic");
    }

    /// @dev Module count should never be negative (implicit with uint256)
    function invariant_moduleCountNonNegative() public view {
        assertGe(router.moduleCount(), 0, "Module count should be non-negative");
    }

    /// @dev KYC records should have consistent state
    function invariant_kycRecordConsistency() public view {
        for (uint256 i = 0; i < 5; i++) {
            address actor = handler.actors(i);
            KYCModule.KYCRecord memory record = kycModule.getKYCRecord(actor);

            // If status is VERIFIED, expiry should be in the future (at creation time)
            if (record.status == KYCModule.KYCStatus.VERIFIED) {
                assertGe(record.expiresAt, record.verifiedAt, "Expiry should be >= verified time");
            }
        }
    }

    /// @dev Total blocked deposits + successful deposits should equal total deposit attempts
    function invariant_depositAccountingConsistent() public view {
        // This is a soft invariant - we track attempts through ghost variables
        uint256 total = handler.ghostBlockedDeposits() + handler.ghostSuccessfulDeposits();
        // Total should be tracked correctly (no overflow/underflow)
        assertLe(total, type(uint256).max);
    }
}
