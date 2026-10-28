# Contribution Guidelines for FOBIC

We welcome contributions to FOBIC! Whether you're fixing bugs, adding new features, or improving documentation, your help is greatly appreciated. Please follow these guidelines to ensure a smooth contribution process.

## How to Contribute

There are several ways you can contribute to FOBIC:
- **Report Issues**: If you encounter any bugs or issues, please report them on the [GitHub Issues](https://github.com/boehringer-ingelheim/fobic/issues) page.
- **Suggest Features**: If you have ideas for new features or improvements, feel free to suggest them on the [GitHub Issues](https://github.com/boehringer-ingelheim/fobic/issues) page.
- **Submit Pull Requests**: If you want to contribute code, after creating an issue, please follow the steps below to submit a pull request.

### Submitting a Pull Request

1. **Fork the Repository**: Start by forking the FOBIC repository to your own GitHub account.
2. **Clone the Repository**: Clone your forked repository to your local machine using the following command:
   ```bash
   git clone https://github.com/your-username/fobic.git
    ```
3. **Create a Branch**: Create a new branch for your feature or bug fix. Use a descriptive name for your branch:
    ```bash
    git checkout -b feature/your-feature-name
    ```
4. **Make Changes**: Make your changes in the codebase. Follow best practices for coding and ensure your code is well-documented.
5. **Test the build locally**: Before submitting your changes, make sure to test the [build locally](README.md#local-development) to ensure everything works as expected. If you're enabling GitHub actions on your fork, you can also test the build in CI by pushing your branch to your fork and checking the Actions tab for the build status. If you have enough space on you machine, you can also test the image in a new virtual machine (VM). Keep in mind, however, that every new installation occupies a spot in you max allowed machines in your EntraID/Intune account.
6. **Open a Pull Request**: Once your changes are ready, open a pull request against the main FOBIC repository. Provide a clear description of your changes, which issues are you fixing/closing and any relevant context. At this time the CI will run the build and will publish the image under the `feat-{name}` or `fix-{name}` tag for testing. If you want to test the image in a new VM, you can use the following command:
    ```bash
    sudo bootc switch ghcr.io/boehringer-ingelheim/fobic:feat-{name}
    ```
