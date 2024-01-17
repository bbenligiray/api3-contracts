import * as helpers from '@nomicfoundation/hardhat-network-helpers';
import { expect } from 'chai';
import { ethers } from 'hardhat';

function signHash(signers, hashType, hash, timestamp) {
  return signers.map((signer) =>
    signer.signMessage(
      ethers.toBeArray(ethers.solidityPackedKeccak256(['bytes32', 'bytes32', 'uint256'], [hashType, hash, timestamp]))
    )
  );
}

describe('HashRegistry', function () {
  async function deploy() {
    const hashTypeA = ethers.solidityPackedKeccak256(['string'], ['Hash type A']);
    const hashTypeB = ethers.solidityPackedKeccak256(['string'], ['Hash type B']);

    const roleNames = ['deployer', 'owner', 'randomPerson'];
    const accounts = await ethers.getSigners();
    const roles = roleNames.reduce((acc, roleName, index) => {
      return { ...acc, [roleName]: accounts[index] };
    }, {});
    const sortedHashTypeASigners = Array.from({ length: 3 })
      .map(() => ethers.Wallet.createRandom())
      .sort((a, b) => (BigInt(a.address) > BigInt(b.address) ? 1 : -1));
    const sortedHashTypeBSigners = Array.from({ length: 2 })
      .map(() => ethers.Wallet.createRandom())
      .sort((a, b) => (BigInt(a.address) > BigInt(b.address) ? 1 : -1));

    const HashRegistry = await ethers.getContractFactory('HashRegistry', roles.deployer);
    const hashRegistry = await HashRegistry.deploy(roles.owner.address);

    return {
      hashTypeA,
      hashTypeB,
      roles,
      sortedHashTypeASigners,
      sortedHashTypeBSigners,
      hashRegistry,
    };
  }

  async function deployAndSetSigners() {
    const { hashTypeA, hashTypeB, roles, sortedHashTypeASigners, sortedHashTypeBSigners, hashRegistry } =
      await deploy();

    await hashRegistry.connect(roles.owner).setSigners(
      hashTypeA,
      sortedHashTypeASigners.map((signer) => signer.address)
    );
    await hashRegistry.connect(roles.owner).setSigners(
      hashTypeB,
      sortedHashTypeBSigners.map((signer) => signer.address)
    );
    return {
      hashTypeA,
      hashTypeB,
      roles,
      sortedHashTypeASigners,
      sortedHashTypeBSigners,
      hashRegistry,
    };
  }

  describe('constructor', function () {
    it('constructs', async function () {
      const { roles, hashRegistry } = await helpers.loadFixture(deploy);
      expect(await hashRegistry.owner()).to.equal(roles.owner.address);
    });
  });

  describe('setSigners', function () {
    context('Sender is the owner', function () {
      context('Hash type is not zero', function () {
        context('Signers are not empty', function () {
          context('First signer address is not zero', function () {
            context('Signer addresses are in ascending order', function () {
              it('sets signers', async function () {
                const { hashTypeA, roles, sortedHashTypeASigners, hashRegistry } = await helpers.loadFixture(deploy);
                expect(await hashRegistry.hashTypeToSignersHash(hashTypeA)).to.equal(ethers.ZeroHash);
                await expect(
                  hashRegistry.connect(roles.owner).setSigners(
                    hashTypeA,
                    sortedHashTypeASigners.map((signer) => signer.address)
                  )
                )
                  .to.emit(hashRegistry, 'SetSigners')
                  .withArgs(
                    hashTypeA,
                    sortedHashTypeASigners.map((signer) => signer.address)
                  );
                expect(await hashRegistry.hashTypeToSignersHash(hashTypeA)).to.equal(
                  ethers.solidityPackedKeccak256(
                    ['address[]'],
                    [sortedHashTypeASigners.map((signer) => signer.address)]
                  )
                );
              });
            });
            context('Signer addresses are not in ascending order', function () {
              it('reverts', async function () {
                const { hashTypeA, roles, sortedHashTypeASigners, hashRegistry } = await helpers.loadFixture(deploy);
                const unsortedHashTypeASigners = [...sortedHashTypeASigners.slice(1), sortedHashTypeASigners[0]];
                await expect(
                  hashRegistry.connect(roles.owner).setSigners(
                    hashTypeA,
                    unsortedHashTypeASigners.map((signer) => signer.address)
                  )
                ).to.be.revertedWith('Signers not in ascending order');
                const duplicatedHashTypeASigners = [sortedHashTypeASigners[1], ...sortedHashTypeASigners.slice(1)];
                await expect(
                  hashRegistry.connect(roles.owner).setSigners(
                    hashTypeA,
                    duplicatedHashTypeASigners.map((signer) => signer.address)
                  )
                ).to.be.revertedWith('Signers not in ascending order');
              });
            });
          });
          context('First signer address is zero', function () {
            it('reverts', async function () {
              const { hashTypeA, roles, sortedHashTypeASigners, hashRegistry } = await helpers.loadFixture(deploy);
              const hashTypeASignersStartingWithZeroAddress = [
                { address: ethers.ZeroAddress },
                ...sortedHashTypeASigners.slice(1),
              ];
              await expect(
                hashRegistry.connect(roles.owner).setSigners(
                  hashTypeA,
                  hashTypeASignersStartingWithZeroAddress.map((signer) => signer.address)
                )
              ).to.be.revertedWith('First signer address zero');
            });
          });
        });
        context('Signers are empty', function () {
          it('reverts', async function () {
            const { hashTypeA, roles, hashRegistry } = await helpers.loadFixture(deploy);
            await expect(hashRegistry.connect(roles.owner).setSigners(hashTypeA, [])).to.be.revertedWith(
              'Signers empty'
            );
          });
        });
      });
      context('Hash type is zero', function () {
        it('reverts', async function () {
          const { roles, sortedHashTypeASigners, hashRegistry } = await helpers.loadFixture(deploy);
          await expect(
            hashRegistry.connect(roles.owner).setSigners(
              ethers.ZeroHash,
              sortedHashTypeASigners.map((signer) => signer.address)
            )
          ).to.be.revertedWith('Hash type zero');
        });
      });
    });
    context('Sender is not the owner', function () {
      it('reverts', async function () {
        const { hashTypeA, roles, sortedHashTypeASigners, hashRegistry } = await helpers.loadFixture(deploy);
        await expect(
          hashRegistry.connect(roles.randomPerson).setSigners(
            hashTypeA,
            sortedHashTypeASigners.map((signer) => signer.address)
          )
        ).to.be.revertedWith('Ownable: caller is not the owner');
      });
    });
  });

  describe('registerHash', function () {
    context('Timestamp is not from the future', function () {
      context('Timestamp is more recent than the previous one', function () {
        context('Signers are set for the hash type', function () {
          context('All signatures match', function () {
            it('registers hash', async function () {
              const { hashTypeA, roles, sortedHashTypeASigners, hashRegistry } =
                await helpers.loadFixture(deployAndSetSigners);
              const hash = ethers.hexlify(ethers.randomBytes(32));
              const timestamp = await helpers.time.latest();
              const signatures = await signHash(sortedHashTypeASigners, hashTypeA, hash, timestamp);
              const hashBefore = await hashRegistry.hashes(hashTypeA);
              expect(hashBefore.value).to.equal(ethers.ZeroHash);
              expect(hashBefore.timestamp).to.equal(0);
              expect(await hashRegistry.getHashValue(hashTypeA)).to.equal(ethers.ZeroHash);
              await expect(
                hashRegistry.connect(roles.randomPerson).registerHash(hashTypeA, hash, timestamp, signatures)
              )
                .to.emit(hashRegistry, 'RegisteredHash')
                .withArgs(hashTypeA, hash, timestamp);
              const hashAfter = await hashRegistry.hashes(hashTypeA);
              expect(hashAfter.value).to.equal(hash);
              expect(hashAfter.timestamp).to.equal(timestamp);
              expect(await hashRegistry.getHashValue(hashTypeA)).to.equal(hash);
            });
          });
          context('Not all signatures match', function () {
            it('reverts', async function () {
              const { hashTypeA, roles, sortedHashTypeBSigners, hashRegistry } =
                await helpers.loadFixture(deployAndSetSigners);
              const hash = ethers.hexlify(ethers.randomBytes(32));
              const timestamp = await helpers.time.latest();
              // Sign with the wrong signers
              const signatures = await signHash(sortedHashTypeBSigners, hashTypeA, hash, timestamp);
              await expect(
                hashRegistry.connect(roles.randomPerson).registerHash(hashTypeA, hash, timestamp, signatures)
              ).to.be.revertedWith('Signature mismatch');
            });
          });
        });
        context('Signers are not set for the hash type', function () {
          it('reverts', async function () {
            const { hashTypeA, roles, sortedHashTypeASigners, hashRegistry } = await helpers.loadFixture(deploy);
            const hash = ethers.hexlify(ethers.randomBytes(32));
            const timestamp = await helpers.time.latest();
            const signatures = await signHash(sortedHashTypeASigners, hashTypeA, hash, timestamp);
            await expect(
              hashRegistry.connect(roles.randomPerson).registerHash(hashTypeA, hash, timestamp, signatures)
            ).to.be.revertedWith('Signers not set');
          });
        });
      });
      context('Timestamp is not more recent than the previous one', function () {
        it('reverts', async function () {
          const { hashTypeA, roles, sortedHashTypeASigners, hashRegistry } =
            await helpers.loadFixture(deployAndSetSigners);
          const hash = ethers.hexlify(ethers.randomBytes(32));
          const timestamp = await helpers.time.latest();
          const signatures = await signHash(sortedHashTypeASigners, hashTypeA, hash, timestamp);
          await hashRegistry.connect(roles.randomPerson).registerHash(hashTypeA, hash, timestamp, signatures);
          await expect(
            hashRegistry.connect(roles.randomPerson).registerHash(hashTypeA, hash, timestamp, signatures)
          ).to.be.revertedWith('Timestamp not more recent');
        });
      });
    });
    context('Timestamp is from the future', function () {
      it('reverts', async function () {
        const { hashTypeA, roles, sortedHashTypeASigners, hashRegistry } =
          await helpers.loadFixture(deployAndSetSigners);
        const hash = ethers.hexlify(ethers.randomBytes(32));
        const timestamp = (await helpers.time.latest()) + 3600;
        const signatures = await signHash(sortedHashTypeASigners, hashTypeA, hash, timestamp);
        await expect(
          hashRegistry.connect(roles.randomPerson).registerHash(hashTypeA, hash, timestamp, signatures)
        ).to.be.revertedWith('Timestamp from future');
      });
    });
  });
});

module.exports = { signHash };
