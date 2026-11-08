# KU Marketplace — Authentication Setup and Testing Guide

**Project:** KU Marketplace  
**Technology Stack:** Swift/Vapor, SQLite, Docker, Expo/React Native, TypeScript  
**Development Environment:** Windows, VS Code, PowerShell, and Expo Go

## Overview

This guide explains how to configure, run, and test the KU Marketplace authentication system locally.

The authentication system supports student registration, university email validation, email verification, secure login, session persistence, and logout.

The backend is implemented using Swift/Vapor with SQLite for persistent storage, while the frontend uses Expo/React Native with TypeScript. Docker provides a consistent backend development environment, and Expo Go allows the mobile application to be tested on a physical device.

The guide covers:

- Setting up the development environment
- Running the backend using Docker
- Configuring and launching the mobile application
- Registering and verifying student accounts
- Testing login, session persistence, and logout
- Running automated tests
- Troubleshooting common setup and connectivity issues
- Security considerations for production deployment

**Note:** Development email verification is intended for local testing. Production deployment requires a properly configured email delivery service and HTTPS.
