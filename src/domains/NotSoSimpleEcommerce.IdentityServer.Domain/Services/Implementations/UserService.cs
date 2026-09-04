using System.Security.Cryptography;
using System.Text;
using Microsoft.EntityFrameworkCore;
using NotSoSimpleEcommerce.IdentityServer.Domain.Models;
using NotSoSimpleEcommerce.IdentityServer.Domain.Services.Contracts;
using NotSoSimpleEcommerce.Repositories.Contracts;
using NotSoSimpleEcommerce.Shared.InOut.Requests;

namespace NotSoSimpleEcommerce.IdentityServer.Domain.Services.Implementations
{
    public sealed class UserService : IUserService
    {
        private readonly IReadEntityRepository<UserEntity> _readRepository;
        public UserService(IReadEntityRepository<UserEntity> readRepository)
        {
            _readRepository = readRepository ?? throw new ArgumentNullException(nameof(readRepository));
        }

        public async Task<bool> CheckPasswordAsync(AuthRequest userRequest)
        {
            var user = await _readRepository.GetAll()
                .FirstOrDefaultAsync(user => user.Email == userRequest.Email);

            // usuario inexistente e falha de autenticacao, nao erro: lancar aqui
            // vira 500 no GlobalErrorHandlerMiddleware e esconde o 401 do controller.
            if (user is null)
                return false;

            var hashedPassword = Encoding.UTF8.GetString(SHA256.HashData(Encoding.UTF8.GetBytes(userRequest.Password)));
            return user.Password == hashedPassword;
        }
    }
}
