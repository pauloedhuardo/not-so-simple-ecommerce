using Microsoft.AspNetCore.Mvc;

namespace NotSoSimpleEcommerce.Main.Controllers
{
    [ApiController]
    [Route("api/hello")]
    public class HelloWorldController : ControllerBase
    {
        [HttpGet]
        public IActionResult Get()
        {
            return Ok(new
            {
                message = "Hello World v1 from Main Service!",
                version = "v1",
                timestamp = DateTime.UtcNow
            });
        }
    }
}
