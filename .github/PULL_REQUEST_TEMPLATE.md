# Pull Request Template

## Basic Information

### JIRA Ticket
<!-- Link to the JIRA ticket associated with this PR -->
**JIRA:** [TICKET-NUMBER](https://confluent.atlassian.net/browse/TICKET-NUMBER)

### Description
<!-- Provide a short, clear description of the change -->
**Summary:** 


---

## Mandatory Testing ⚠️

**🚨 TESTING IS REQUIRED - Screenshots must be provided for all testing steps below 🚨**

### Step 1: Semaphore Job Image Verification

1. **Find the built image in Semaphore job logs:**
   - Navigate to the Semaphore job for this PR
   - Search for `.arm64` in the logs to find the image URL
   - Example format: `519856050701.dkr.ecr.us-west-2.amazonaws.com/docker/dev/confluentinc/cp-enterprise-control-center-next-gen:dev-2.3.x-f310d12b-ubi9.arm64`

**📸 Screenshot Required:** Semaphore job logs showing the image URL

### Step 2: Docker Compose Integration Testing

2. **Update cp-all-in-one docker-compose.yml:**
   - Clone or access: https://github.com/confluentinc/cp-all-in-one
   - Update the Control Center image in the docker-compose.yml file at these locations:
     - [Line 94](https://github.com/confluentinc/cp-all-in-one/blob/8.0.0-post/cp-all-in-one/docker-compose.yml#L94)
     - [Line 106](https://github.com/confluentinc/cp-all-in-one/blob/8.0.0-post/cp-all-in-one/docker-compose.yml#L106)
     - [Line 120](https://github.com/confluentinc/cp-all-in-one/blob/8.0.0-post/cp-all-in-one/docker-compose.yml#L120)
   - Replace the existing Control Center image with your built image URL from Step 1

**📸 Screenshot Required:** Modified docker-compose.yml showing the updated image references

### Step 3: Control Center Startup Verification

3. **Verify Control Center startup:**
   - Run `docker-compose up -d` in the cp-all-in-one directory
   - Wait for all services to start
   - Verify Control Center is accessible and functioning properly
   - Check that Control Center UI loads without errors

**📸 Screenshots Required:** 
- Docker compose startup logs showing successful Control Center initialization
- Control Center UI homepage showing it's running properly
- Any relevant logs confirming functionality

---

## Testing Checklist

- [ ] Semaphore job completed successfully and image URL identified
- [ ] Docker compose file updated with new image
- [ ] Control Center starts up successfully
- [ ] Control Center UI is accessible and functional
- [ ] All required screenshots provided above

