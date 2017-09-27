pragma solidity 0.4.15;

// Using the Open Zeppelin's tested code
import 'github.com/OpenZeppelin/zeppelin-solidity/contracts/ownership/Ownable.sol';
import 'github.com/OpenZeppelin/zeppelin-solidity/contracts/math/SafeMath.sol';
import "github.com/oraclize/ethereum-api/oraclizeAPI.sol";

// For the sake of simplicity lets asume USD is a ERC20 token
// Also lets asume we can 100% trust the exchange rate oracle
contract PayrollInterface {

  /* OWNER ONLY */
  function addEmployee(address accountAddress, address[] allowedTokens, uint256 initialYearlyUSDSalary);
  function setEmployeeSalary(uint256 employeeId, uint256 yearlyUSDSalary);
  function removeEmployee(uint256 employeeId);

  function addFunds() payable;
  function scapeHatch();
  // function addTokenFunds()? // Use approveAndCall or ERC223 tokenFallback

  function getEmployeeCount() constant returns (uint256);
  function getEmployee(uint256 employeeId) constant returns (address employee); // Return all important info too

  function calculatePayrollBurnrate() constant returns (uint256); // Monthly usd amount spent in salaries
  function calculatePayrollRunway() constant returns (uint256); // Days until the contract can run out of funds

  /* EMPLOYEE ONLY */
  function determineAllocation(address[] tokens, uint256[] distribution); // only callable once every 6 months
  function payday(); // only callable once a month

  /* ORACLE ONLY */
  function setExchangeRate(address token, uint256 usdExchangeRate); // uses decimals from token
}

/// @title The payroll contract that will be used to pay the salary of the workers
/// @author Merunas Grincalaitis <merunasgrincalaitis@gmail.com>
contract Payroll is PayrollInterface, Ownable, usingOraclize{
   using SafeMath for uint256;

   // The data stored for each employee
   struct Employee {
      address accountAddress;
      address[] allowedTokens;
      uint256[] tokenDistribution;
      uint256 yearlySalary;
      uint256 lastTimeCalled; // Timestamp
      uint256 lastTimePayed;
   }

   // Each token data
   struct Token {
      string symbol;
      uint256 priceUsd;
      uint256 lastUpdated; // Timestamp
   }

   // To locate each employee with his ID => Employee data
   mapping(uint256 => Employee) employees;

   // To be able to get the ID of an employee given his address and get the rest
   // of the data
   mapping(address => uint256) employeesIds;

   // To define the price of each token
   mapping(address => Token) tokens;

   // To set the ID of each employee
   uint256 employeeIdCounter = 0;

   // How much total USD is spent monthly in salaries
   uint256 totalMonthlySalaries;

   // The address that will store the ether
   address etherAddress;

   // The address of the ANT token
   address aragonToken;
   uint256 antPrice;
   uint256 ethPrice;

   // To notify users about approvals
   event LogApproval(address from, uint256 value, address tokenContract, bytes extraData);

   modifier onlyEmployee() {
      require(employees[msg.sender])
   }

   /// @notice Constructor only used to set the proof of oraclize
   function Payroll() {
      oraclize_setProof(proofType_Ledger);
   }

   /// @notice To add a new employee to the business
   /// @param accountAddress Where the funds paid will be stored
   /// @param allowedTokens The array used to store what tokens he's allowed to use
   /// @param initialYearlyUSDSalary The initial yearly salary of that employee in USD
   function addEmployee(
      address accountAddress,
      address[] allowedTokens,
      uint256 initialYearlyUSDSalary
   ) onlyOwner{
      require(accountAddress != address(0));
      require(initialYearlyUSDSalary > 0);

      employeeIdCounter = employeeIdCounter.add(1);
      employees[employeeIdCounter].accountAddress = accountAddress;
      employees[employeeIdCounter].allowedTokens = allowedTokens;
      employees[employeeIdCounter].yearlySalary = initialYearlyUSDSalary;
      employees[employeeIdCounter].lastTimeCalled = block.timestamp;
      employees[employeeIdCounter].lastTimePayed = block.timestamp;
      employeesIds[accountAddress] = employeeIdCounter;

      updateTotalMonthlySalaries(0, initialYearlyUSDSalary);
   }

   /// @notice To set the salary of a specified employee
   /// @param employeeId The ID of that employee used to modify his salary
   /// @param yearlyUSDSalary The new yearly salary that will be used for him
   function setEmployeeSalary(uint256 employeeId, uint256 yearlyUSDSalary) onlyOwner {
      require(employeeId > 0);
      require(yearlyUSDSalary > 0);

      // Checking that the employee exists
      require(employees[employeeId].accountAddress != address(0));

      uint256 salaryBefore = employees[employeeId].yearlySalary;

      employees[employeeId].yearlySalary = yearlyUSDSalary;
      updateTotalMonthlySalaries(salaryBefore, yearlyUSDSalary);
   }

   /// @notice Removes an exployee from the list, mapping of employees
   /// @param employeeId The ID of the employee to delete
   function removeEmployee(uint256 employeeId) onlyOwner {
      require(employeeId > 0);
      require(employees[employeeId].accountAddress != address(0));

      delete employees[employeeId];
   }

   /// @notice Used by aproveAndCall to confirm that the approval was executed
   /// successfully and get notified
   /// @param _from The address that approved to use the token
   /// @param _value The amount of tokens approved to use
   /// @param _tokenContract The address of the token that executed the approval
   /// @param _extraData Extra data that could be interesting for the user
   function receiveApproval(address _from, uint256 _value, address _tokenContract, bytes _extraData) {
      LogApproval(_from, _value, _tokenContract, _extraData);
   }

   /// @notice To add funds to the contract in order to use them later to pay the
   /// employees. Only used to store the ether sent
   function addFunds() payable {}

   /// @notice To extract the ether from the contract
   function scapeHatch() onlyOwner {
      msg.sender.transfer(this.balance);
   }

   /// @notice Updates the `totalMonthlySalaries` when a salary is changed or created
   /// in order to keep a record of how much total USD is spent each month in salaries
   /// @param salaryBefore How much the employee was earning before the update
   /// @param salaryAfter How much the employee will earn after the update
   function updateTotalMonthlySalaries(uint256 salaryBefore, uint256 salaryAfter) internal {
      require(salaryAfter > 0 && salaryAfter > salaryBefore);

      totalMonthlySalaries = totalMonthlySalaries.sub(salaryBefore);
      totalMonthlySalaries = totalMonthlySalaries.add(salaryAfter);
   }

   /// @notice To get how many employees are available
   /// @return uint256 The number of employees
   function getEmployeeCount() constant returns(uint256) {
      return employeeIdCounter;
   }

   /// @notice To get the employee data given his ID
   /// @param employeeId The ID of that employee
   /// @return employee The address of the employee
   /// @return allowedTokens The tokens that he's allowed to use
   /// @return yearlySalary How much that employee gets paid each year in USD
   function getEmployee(uint256 employeeId) constant returns(
      address employee,
      address[] allowedTokens,
      uint256 yearlySalary
   ) {
      require(employeeId > 0 && employeeId <= employeeIdCounter);

      employee = employees[employeeId].accountAddress;
      allowedTokens = employees[employeeId].allowedTokens;
      yearlySalary = employees[employeeId].yearlySalary;
   }

   /// @notice Returns how much USD is spent each month in salaries
   /// @return uint256 The number of USD spent
   function calculatePayrollBurnrate() constant returns(uint256) {
      return totalMonthlySalaries;
   }

   /// @notice Returns how many days until the contract runs out of funds
   /// @return uint256 The number of days left
   function calculatePayrollRunway() constant returns(uint256) {
      uint256 paymentPerDay = totalMonthlySalaries.div(30);

      return this.balance.div(paymentPerDay);
   }

   /// @notice To establish what percentage of each token will be used to pay the salary
   /// of this employee. Only callable once every 6 months by the employee
   /// @param _tokens The array of tokens used to pay the salary of this employee
   /// @param distribution The percentages for each token up to 100 which is 100%
   function determineAllocation(address[] _tokens, uint256[] distribution) onlyEmployee {
      require(_tokens.length > 0);
      require(distribution.length > 0);

      // Check if 6 months have passed to
      require(block.timestamp >= employeesIds[accountAddress].lastTimeCalled.add(90 days));

      uint256 employeeId = employeesIds[accountAddress];
      employees[employeeId].lastTimeCalled = block.timestamp;
      employees[employeeId].allowedTokens = _tokens;
      employees[employeeId].tokenDistribution = distribution;
   }

   /// @notice To distribute the payment of the employee with the corresponding
   /// token allocation. You must call it 2 times: first to update the price of
   /// the tokens and another one to get paid. Only payable once a month
   function payday() onlyEmployee {
      require(block.timestamp >= employeesIds[accountAddress].lastTimePayed.add(30 days));

      uint256 employeeId = employeesIds[accountAddress];
      address[] _tokens = employees[employeeId].allowedTokens;
      uint256[] distributions = employees[employeeId].tokenDistribution;
      uint256 monthlySalary = employees[employeeId].yearlyUSDSalary.div(12);

      // Distribute the payment depending on the allocation for each token
      for(uint i = 0; i < _tokens.length; i++) {

         // Distribute the tokens after updating the price. Limited to 60 mins
         if(_tokens[i].lastUpdated.add(60 minutes) >= block.timestamp) {

         }

         uint256 paymentToken = distributions[i].div(100).mul(monthlySalary);
         _tokens[i]
      }
   }

   /// @notice Callback function that gets called by oraclize when the price of
   /// the tokens gets updated. It constantly updates the price of Ether and the
   /// ANT token
   /// @param _queryId The query id that was generated to proofVerify
   /// @param _result String that contains the number generated
   /// @param _proof A string with a proof code to verify the authenticity of the number generation
   function __callback(
      bytes32 _queryId,
      string _result,
      bytes _proof
   ) oraclize_randomDS_proofVerify(_queryId, _result, _proof) {
      require(msg.sender == oraclize_cbAddress());

      uint256 price = uint(_result);

      // If the price is less than 100, then update the price of ANT. It's not a
      // perfect mechanism to specify the price of each token but it works
      if(price < 100)
         antPrice = price;
      else
         ethPrice = price;

      // Renew the prices for each token using the Oraclize API each day
      // ETH price query
      oraclize_query(1 days, "URL", "json(https://coinmarketcap-nexuist.rhcloud.com/api/eth).price.usd");

      // ANT price query
      oraclize_query(1 days, "URL", "json(https://coinmarketcap-nexuist.rhcloud.com/api/ant).price.usd");
   }
}
