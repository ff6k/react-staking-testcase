import './App.css';
import { useState } from 'react';
import { ethers, BigNumber } from 'ethers';
import PRNTRUSDCpoolFarmingVariant from './artifacts/contracts/PRNTRUSDCpoolFarmingVariant.sol/PRNTRUSDCpoolFarmingVariant.json'

// Update with the contract address logged out to the CLI when it was deployed 
const contractAddress = "0xfDA1cF6261DcAbAa29b3e464f78717FFb54b8A63"

function App() {
  // store greeting in local state
  const [stakeAmount, setStakeAmountValue] = useState()
  const [withdrawAmount, setWithdrawAmountValue] = useState()

  // request access to the user's MetaMask account
  async function requestAccount() {
    await window.ethereum.request({ method: 'eth_requestAccounts' });
  }
  // call the smart contract, send an stake
  async function doStake() {
    if (!stakeAmount) return
    if (typeof window.ethereum !== 'undefined') {
      await requestAccount()
      const provider = new ethers.providers.Web3Provider(window.ethereum);
      const signer = provider.getSigner();
      const contract = new ethers.Contract(contractAddress, PRNTRUSDCpoolFarmingVariant.abi, signer)
      const transaction = await contract.deposit(stakeAmount)
      await transaction.wait()
    }
  }

  // call the smart contract, send an stake
  async function doWithdraw() {
    if (!withdrawAmount) return
    if (typeof window.ethereum !== 'undefined') {
      await requestAccount()
      const provider = new ethers.providers.Web3Provider(window.ethereum);
      const signer = provider.getSigner()
      const contract = new ethers.Contract(contractAddress, PRNTRUSDCpoolFarmingVariant.abi, signer)
      const transaction = await contract.withdraw(withdrawAmount)
      await transaction.wait()
    }
  }

  // call the smart contract, send an stake
  async function doClaim() {
    if (typeof window.ethereum !== 'undefined') {
      await requestAccount()
      const provider = new ethers.providers.Web3Provider(window.ethereum);
      const signer = provider.getSigner()
      const contract = new ethers.Contract(contractAddress, PRNTRUSDCpoolFarmingVariant.abi, signer)
      const transaction = await contract.claim()
      await transaction.wait()
    }
  }
  return (
    <div className="App">
      <header className="App-header">
        <div>
          <input onChange={e => setStakeAmountValue(e.target.value)} placeholder="Set stake amount" />
          <button onClick={doStake}>Stake</button>
        </div>
        <div>
          <input onChange={e => setWithdrawAmountValue(e.target.value)} placeholder="Set withdraw amount" />
          <button onClick={doWithdraw}>Withdraw</button>
        </div>
        <div>
          <button onClick={doClaim}>Claim</button>
        </div>

      </header>
    </div>
  );
}

export default App;